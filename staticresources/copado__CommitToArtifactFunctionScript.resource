#!/usr/bin/env node
'use strict';

/**
 * Git Diff Auto-Commit
 *
 * Instead of receiving an explicit file selection from the user, this function:
 *  1.  Clones the base branch into TARGET_DIRECTORY.
 *  2.  Fetches the base branch origin (for merge-base calculation only).
 *  3.  Configures git and creates feature/<userStoryName> from the base branch tip.
 *  4.  Resolves merge-base (historical fork validation + shallow deepen until reachable).
 *  5.  Diffs <divergenceSHA>...<baseBranch> to obtain added/modified and deleted paths (empty diff still continues to push/merge). Logs use [Step 1/8]…[Step 8/8] for client-readable progress.
 *  6.  Resolves diff paths to metadata name/type via enricher --changefile (like file-difference analysis).
 *  7.  Writes the Copado change list [{ n, t, a, c }] to COMMIT_CHANGES_FILE_PATH.
 *  8.  Runs enricher -p --quick true to populate j.filePath for every entry.
 *  9.  Runs varreplace + yamlreplace (find & replace) on the filtered files.
 * 10.  Runs metadata-processor.
 * 11.  Checks git status for real changes.
 * 12.  git add + git commit + git push feature branch.
 * 13.  Checks out the environment branch → merges feature branch in → pushes.
 *
 * Required environment variables:
 *   baseBranch             – branch that contains the work-in-progress changes
 *   baseBranchOrigin       – branch to diff against (merge-base anchor)
 *   environmentBranch      – branch that receives the merged feature branch
 *   userStoryName          – user story name; used to derive the feature branch (feature/<userStoryName>)
 *   userStoryId            – Salesforce record id of the User Story; used for file uploads
 *   repositoryId           – Salesforce record id of the Repository
 *   gitEmail / gitName     – git identity
 *   gitDepth               – shallow clone depth (default 100)
 *   chunkSize              – chunk size for git add batching
 *   overriddenApiVersion / API_VERSION – Salesforce API version
 *
 * Optional environment variables:
 *   recreateFeatureBranch  – if truthy, deletes and recreates the feature branch
 *   featureBranchName      – override the auto-derived feature/<userStoryName> branch name
 *   releaseId              – Salesforce record id of the Release (informational)
 *   commitMessage          – commit message override
 *   findAndReplaceFileId   – Copado file id for the Copado.yml F&R rules
 *   sourceEnv              – JSON array of env-var replacement pairs
 */

const child_process = require('child_process'),
	fs = require('fs'),
	https = require('https'),
	process = require('process'),
	path = require('path');

const {
	baseBranch,
	baseBranchOrigin,
	environmentBranch,
	userStoryName,
	userStoryId,
	recreateFeatureBranch,
	featureBranchName,
	commitMessage,
	gitEmail,
	gitName,
	gitDepth,
	findAndReplaceFileId,
	sourceEnv,
	API_VERSION,
	chunkSize,
	vlocityFilesPath,
	isTest,
	overriddenApiVersion
} = process.env;

// ─── paths ────────────────────────────────────────────────────────────────────
const TEMP_DIRECTORY = getPath('/tmp');
const APP_DIRECTORY = getPath('/app');
const TARGET_DIRECTORY = `${APP_DIRECTORY}/repository`;
const COMMIT_CHANGES_FILE_PATH = `${APP_DIRECTORY}/encoded_changes.json`;
const FILES_TO_INCLUDE = `${TEMP_DIRECTORY}/filesToInclude.json`;
const GIT_STATUS_FILE_PATH = `${TEMP_DIRECTORY}/git_status.txt`;
const OUTPUT_JSON_FILE_PATH = `${TEMP_DIRECTORY}/output.json`;
const DIFF_FILE_LIST_PATH = `${TEMP_DIRECTORY}/diffFileList.txt`;
const DIFF_CHANGE_FILE_PATH = `${TEMP_DIRECTORY}/diffChanges`;
const DIFF_CHANGE_ENRICHED_PATH = `${TEMP_DIRECTORY}/diffChanges.json`;
const DIFF_DELETE_CHANGE_FILE_PATH = `${TEMP_DIRECTORY}/diffDeletedChanges`;
const DIFF_DELETE_CHANGE_ENRICHED_PATH = `${TEMP_DIRECTORY}/diffDeletedChanges.json`;
const DELETED_METADATA_DIRECTORY = `${TEMP_DIRECTORY}/deletedMetadataRepository`;

// ─── constants ────────────────────────────────────────────────────────────────
const COMMIT_OPERATION = 'Git Diff Commit Operation';
const COPADO_YML = 'Copado';
const GIT_DEPTH = getGitDepth(gitDepth);
const MAX_MERGE_BASE_FETCH_DEPTH = 2000;
const MAX_MERGE_BASE_DEEPEN_ATTEMPTS = 25;
const USER_STORY_NAME = userStoryName?.trim() || '';
const USER_STORY_ID = userStoryId?.trim() || '';
const SHOULD_RECREATE_FEATURE_BRANCH = isTruthyFlag(recreateFeatureBranch);
const FEATURE_BRANCH = featureBranchName?.trim() || (USER_STORY_NAME ? `feature/${USER_STORY_NAME}` : '');
const COPADO_INFO_PREFIX = 'CopadoFunction INFO';
const WORKFLOW_STEP_COUNT = 8;
const COPADO_COMMIT_CHANGES_FILE_NAME = 'Copado Commit Changes';
const MAX_METADATA_CHANGES_PER_USER_STORY = 8000;
const MAX_METADATA_CHANGES_ERROR_MESSAGE =
	'You cannot commit more than 8000 changes to a single user story. If you need to commit all these changes, split them into different user stories.';

const CATEGORY = { SFDX: 'sfdx' };
const ACTIONS = { ADD: 'add', DELETE: 'delete' };

const PORCELAIN_STATUS = {
	ADDED: 'A',
	DELETED: 'D',
	UNMERGED: 'U'
};

const RESULT_INFO = {
	LEVEL: { INFO: 'INFO', ERROR: 'ERROR', WARN: 'WARN' },
	CATEGORY: {
		UNKNOWN_EXCEPTION: 'Unknown Exception',
		COPADO_INFO: 'Copado Info',
		GIT: 'Git',
		COPADO_SERVICE: 'Copado Service',
		SFDX_CLI: 'Salesforce CLI',
		FILE_SYSTEM: 'File System',
		GIT_SERVICE: 'Git Service',
		COMMIT_INFO: 'Commit Info',
		COPADO_METADATA_INTELLIGENCE: 'Copado Metadata Intelligence'
	},
	ADDITIONAL_INFORMATION: {
		GIT_CLONE: 'Git Clone',
		GIT_CONFIG: 'Git Configuration',
		GIT_STATUS: 'Git Status',
		GIT_ADD: 'Git Add',
		GIT_COMMIT: 'Git Commit',
		GIT_PUSH: 'Git Push',
		GIT_CLEAN: 'Git Clean',
		GIT_CHECKOUT: 'Git Checkout',
		GIT_MERGE: 'Git Merge',
		GIT_MERGE_PUSH_FEATURE_BRANCH: 'Git Merge & Push Feature Branch',
		FEATURE_BRANCH_CHECKOUT: 'Feature Branch Checkout',
		DELETE_FEATURE_BRANCH: 'Delete Feature Branch',
		SFDX_CONFIG: 'SFDX Configuration',
		ENRICHER_SERVICE: 'Enricher Service',
		METADATA_PROCESSOR: 'Metadata Processor',
		ENV_VARIABLE_REPLACEMENT: 'Environment Variable Replacement',
		GLOBAL_FIND_AND_REPLACE: 'Global Find and Replace',
		GIT_DIFF: 'Git Diff',
		MERGE_BASE: 'Git Merge Base',
		METADATA_FILTER: 'Metadata Filter',
		UPLOAD_FILES: 'Upload Files',
		DOWNLOAD_FILES: 'Download Files',
		COPY_FILES: 'Copy Files',
		MISSING_DETAILS: 'Missing Details'
	}
};

const CUSTOM_ERROR = { COMMAND_EXECUTION_ERROR: 'CommandExecutionError' };

const RESULT_TABLE_HEADER = {
	label: 'Git Diff Commit Result',
	customLabel: 'Git_Diff_Commit_Result'
};
const HEADER_ICON = 'standard:note';
const RESULT_TABLE_COLUMNS = [
	{ label: 'Level', fieldName: 'Level', type: 'text', wrapText: true, customLabel: 'Level', initialWidth: 80 },
	{ label: 'Category', fieldName: 'Category', type: 'text', wrapText: true, customLabel: 'Category', initialWidth: 120 },
	{
		label: 'Additional Information',
		fieldName: 'AdditionalInformation',
		type: 'text',
		wrapText: true,
		customLabel: 'Additional_Information',
		initialWidth: 200
	},
	{ label: 'Message', fieldName: 'Message', type: 'text', wrapText: true, customLabel: 'Message' }
];

// ─── mutable state ────────────────────────────────────────────────────────────
let totalTimeByType = {};
let processes = new Map();
let resultViewerJson = [];
let executionError;
let executionErrorUserFacing;
let sourceApiVersion = isTest ? API_VERSION : '';

// =============================================================================
// MAIN ENTRY POINT
// =============================================================================

async function execute() {
	try {
		console.time(COMMIT_OPERATION);

		logInputParameters();
		validateInputs();
		logWorkflowOverview();

		// Steps 1-2: clone base branch, fetch base branch origin, configure git, create feature branch
		await initialSetup();
		await copyVlocityFilesIfPresent(vlocityFilesPath);

		// Early idempotency check: if the feature branch HEAD is already reachable from the
		// environment branch, the previous run already committed and merged — nothing left to do.
		await checkAlreadyMergedIntoEnvironmentBranch();

		// Step 3: validate historical fork + resolve merge-base (shallow deepen if needed)
		const divergenceSha = await resolveMergeBaseWithValidation(baseBranchOrigin, baseBranch, GIT_DEPTH);

		// Step 4: diff divergenceSha...baseBranch → raw file list grouped by operation
		const diffChanges = await getDiffFileList(divergenceSha, baseBranch);
		logger(`Changed files (${diffChanges.all.length}): ${diffChanges.all.join(', ')}`);

		if (!diffChanges.all.length) {
			reportNoChanges('No file changes detected in diff.');
		} else {
			// Steps 6-7: enricher --changefile resolves metadata name/type from diff paths
			const { changeList, metadataFiles } = await resolveMetadataFromDiffFiles(diffChanges, divergenceSha);
			logger(`Metadata files after enricher (${metadataFiles.length}): ${metadataFiles.join(', ')}`);
			assertMetadataChangeCountWithinLimit(metadataFiles, changeList);

			if (!changeList.length) {
				reportNoChanges('No SFDX metadata changes detected in diff.');
			} else {
				fs.writeFileSync(COMMIT_CHANGES_FILE_PATH, JSON.stringify(changeList, null, 2));
				logger(`Change list written (${changeList.length} entries)`);
				if (metadataFiles.length) {
					fs.writeFileSync(FILES_TO_INCLUDE, JSON.stringify(metadataFiles));
				} else if (fs.existsSync(FILES_TO_INCLUDE)) {
					fs.rmSync(FILES_TO_INCLUDE);
				}

				// Step 8a: publish the change list to the User Story record (m/j are empty at this point,
				// matching the Copado Commit Changes contract that the enricher expects as input)
				await uploadCopadoCommitChangesToUserStory();

				// Step 8b: enricher -p --quick true (populates j/filePaths into encoded_changes.json)
				await enrichChangeList(COMMIT_CHANGES_FILE_PATH);

				// Step 9: varreplace + yamlreplace (find & replace)
				if (fs.existsSync(FILES_TO_INCLUDE)) {
					await varReplace(sourceEnv, FILES_TO_INCLUDE);
					await findAndReplace(findAndReplaceFileId, FEATURE_BRANCH, FILES_TO_INCLUDE);
				}

				// Step 10: metadata-processor
				await processMetadata();
			}
		}

		// Steps 6-7: git status → add → commit → push feature → merge into environmentBranch
		await commitAndUpdateEnvironmentBranches(GIT_DEPTH);

		console.timeEnd(COMMIT_OPERATION);
	} catch (err) {
		if (err instanceof NoChangesEarlyExit) {
			logger(`Graceful early exit: ${err.message}`);
			const resultData = enrichResultDataWithArtifactContext({ status: 'No Changes' });
			await finishCommit(true, true, 'No Changes - no metadata differences detected between branches', resultData);
			console.timeEnd(COMMIT_OPERATION);
		} else {
			logger(`Error stack: ${err.stack}`);
			if (!(err instanceof CommandExecutionError)) {
				populateResultViewer(RESULT_INFO.LEVEL.ERROR, RESULT_INFO.CATEGORY.UNKNOWN_EXCEPTION, 'See logs for more info', err.message);
			}
			executionError = err.message || err?.toString() || 'Unknown Error occurred';
			executionErrorUserFacing = err instanceof CommandExecutionError && err.userFacing;
		}
	} finally {
		printMetrics();
		logWorkflowStep(8, 'Upload job results to Copado', 'Attaching EnrichedChanges.json and the result viewer summary to this job execution', true);
		if (fs.existsSync(COMMIT_CHANGES_FILE_PATH)) {
			await uploadFile(COMMIT_CHANGES_FILE_PATH, 'EnrichedChanges.json');
		}
		if (resultViewerJson?.length) {
			await uploadResultViewerJson(resultViewerJson, RESULT_TABLE_COLUMNS, RESULT_TABLE_HEADER, HEADER_ICON);
		}
		logWorkflowStepDone(8, 'Upload job results to Copado');
		if (executionError) {
			await executeCommand(getErrorCmdString(executionError, executionErrorUserFacing));
			process.exit(1);
		}
	}
}

// =============================================================================
// STEP 0 – VALIDATION
// =============================================================================

function logInputParameters() {
	const SENSITIVE_ENV_KEYS = new Set(['git_json', 'CF_SF_SESSIONID', 'sourceEnv']);
	const INPUT_PARAMETER_NAMES = [
		'git_json',
		'baseBranch',
		'baseBranchOrigin',
		'environmentBranch',
		'repositoryId',
		'userStoryName',
		'userStoryId',
		'releaseId',
		'recreateFeatureBranch',
		'featureBranchName',
		'commitMessage',
		'gitEmail',
		'gitName',
		'gitDepth',
		'findAndReplaceFileId',
		'sourceEnv',
		'API_VERSION',
		'chunkSize',
		'overriddenApiVersion',
		'timeout',
		'vlocityFilesPath',
		'CF_RESULTID',
		'CF_SF_ENDPOINT'
	];

	logger('========== Input parameters ==========');
	for (const name of INPUT_PARAMETER_NAMES) {
		const value = process.env[name];
		if (SENSITIVE_ENV_KEYS.has(name)) {
			logger(`${name}: ${value ? '[SET, redacted]' : '[NOT SET]'}`);
		} else {
			logger(`${name}: ${value ?? ''}`);
		}
	}
	logger('--- resolved for execution ---');
	logger(`resolved.userStoryName: ${USER_STORY_NAME || '[NOT SET]'}`);
	logger(`resolved.userStoryId: ${USER_STORY_ID || '[NOT SET]'}`);
	logger(`resolved.featureBranch: ${FEATURE_BRANCH || '[NOT SET]'}`);
	logger(`resolved.recreateFeatureBranch: ${SHOULD_RECREATE_FEATURE_BRANCH}`);
	logger(`resolved.commitMessage: ${getCommitMessage()}`);
	logger(`resolved.gitDepth: ${GIT_DEPTH}`);
	logger('======================================');
}

function validateInputs() {
	const missing = [];
	if (!baseBranch) missing.push('baseBranch');
	if (!baseBranchOrigin) missing.push('baseBranchOrigin');
	if (!environmentBranch) missing.push('environmentBranch');
	if (!USER_STORY_NAME) missing.push('userStoryName');
	if (!USER_STORY_ID) missing.push('userStoryId');
	if (missing.length) {
		throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
	}
}

function assertMetadataChangeCountWithinLimit(metadataFiles, changeList) {
	const changeCount = Math.max(metadataFiles?.length ?? 0, changeList?.length ?? 0);
	if (changeCount > MAX_METADATA_CHANGES_PER_USER_STORY) {
		throw new Error(MAX_METADATA_CHANGES_ERROR_MESSAGE);
	}
}

// =============================================================================
// STEPS 1-3 – INITIAL SETUP
// =============================================================================

async function initialSetup() {
	logWorkflowStep(1, 'Clone repository', `Cloning "${baseBranch}" and fetching "${baseBranchOrigin}" as the diff baseline`, true);

	sourceApiVersion = await getApiVersion(overriddenApiVersion, API_VERSION);

	// Step 1: Clone base branch into TARGET_DIRECTORY
	await executeCommand(
		createTargetDirectoryAndFetchBranch(baseBranch, GIT_DEPTH),
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE
	);

	changeWorkingDirectory(TARGET_DIRECTORY);

	// Step 2: Fetch base branch origin (shallow, for merge-base only – no checkout)
	await executeCommand(
		`copado-git-get -g "git fetch origin ${baseBranchOrigin} --depth ${GIT_DEPTH}"`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE,
		true // allowFailure – remote may not have the branch yet
	);

	// Step 3a: Configure git identity
	await configureGit(gitEmail, gitName);

	// Step 2: Create / reuse feature branch from release branch tip
	await fetchCreateFeatureBranch(SHOULD_RECREATE_FEATURE_BRANCH ? 'true' : 'false', FEATURE_BRANCH, GIT_DEPTH);

	logWorkflowStepDone(1, 'Clone repository');
}

async function checkAlreadyMergedIntoEnvironmentBranch() {
	logger(`Checking if the current feature branch commit is already present in ${environmentBranch}...`);

	// Fetch environmentBranch shallowly so we have its remote ref.
	// allowFailure=true: if the branch doesn't exist yet on the remote this check is vacuous.
	await executeCommand(
		`copado-git-get -g "git fetch origin ${environmentBranch} --depth ${GIT_DEPTH}"`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE,
		true
	);

	// git merge-base --is-ancestor exits 0 if HEAD is reachable from origin/environmentBranch,
	// exits 1 (or errors) if not. We capture the result synchronously to avoid reject semantics.
	const featureHead = child_process
		.execFileSync('git', ['rev-parse', 'HEAD'], { cwd: TARGET_DIRECTORY, stdio: 'pipe' })
		.toString()
		.trim();

	let alreadyMerged = false;
	try {
		child_process.execFileSync(
			'git',
			['merge-base', '--is-ancestor', featureHead, `origin/${environmentBranch}`],
			{ cwd: TARGET_DIRECTORY, stdio: 'pipe' }
		);
		alreadyMerged = true;
	} catch {
		alreadyMerged = false;
	}

	if (alreadyMerged) {
		reportNoChanges(
			`Feature branch commit ${featureHead.substring(0, 8)} is already present in ${environmentBranch}. Nothing to commit or merge.`
		);
	}

	logger(`Commit ${featureHead.substring(0, 8)} not yet in ${environmentBranch} — continuing.`);
}

function createTargetDirectoryAndFetchBranch(branch, depth) {
	return `
    mkdir -p ${TARGET_DIRECTORY}
    cd ${TARGET_DIRECTORY}
    copado-git-get --depth "${depth}" "${branch}"`;
}

async function fetchCreateFeatureBranch(recreateIfExists, featureBranch, gitDepth) {
	if (gitDepth === undefined) {
		gitDepth = featureBranch;
		featureBranch = recreateIfExists;
		recreateIfExists = 'false';
	}

	const recreateLabel = recreateIfExists === 'true' ? 'Recreating' : 'Preparing';
	logWorkflowStep(2, 'Set up user story branch', `${recreateLabel} "${featureBranch}" from "${baseBranch}"`, true);
	if (!featureBranch) {
		throw new Error('No feature branch provided');
	}

	let remoteBranchWasDeleted = false;
	if (recreateIfExists === 'true') {
		asyncCopadoLogMessage(`Deleting branch "${featureBranch}"`);
		const deleteOutput = await executeCommand(
			`
            git branch -D "${featureBranch}" || true
            copado-git-get -g "git push origin --delete ${featureBranch}" || true`,
			RESULT_INFO.CATEGORY.GIT_SERVICE,
			RESULT_INFO.ADDITIONAL_INFORMATION.DELETE_FEATURE_BRANCH,
			true
		);
		remoteBranchWasDeleted = /\[deleted\]\s+/i.test(deleteOutput || '');
		if (remoteBranchWasDeleted) {
			logger(`Waiting for remote ref ${featureBranch} to settle on the Git server before recreating it`);
			await sleep(5000);
		}
	}

	asyncCopadoLogMessage(`Checking out "${featureBranch}"`);
	await executeCommand(
		fetchCheckoutBranch(featureBranch, gitDepth, true),
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.FEATURE_BRANCH_CHECKOUT,
		true
	);

	// Always fast-forward the feature branch to the latest tip of baseBranch so
	// the working tree contains all files that will appear in the diff — regardless
	// of whether the feature branch was just created or already existed on the remote.
	asyncCopadoLogMessage(`Syncing "${featureBranch}" with "${baseBranch}"`);
	await executeCommand(
		`git merge "origin/${baseBranch}" --ff-only || git merge "origin/${baseBranch}" -Xignore-space-change`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.FEATURE_BRANCH_CHECKOUT,
		true
	);

	logWorkflowStepDone(2, 'Set up user story branch');
}

// =============================================================================
// STEP 4 – MERGE-BASE (historical fork + shallow deepen)
// =============================================================================

async function resolveMergeBaseWithValidation(parent, working, initialDepth) {
	logWorkflowStep(
		3,
		'Find diff baseline',
		`Finding where "${working}" diverged from "${parent}"`,
		true
	);
	startWatch(RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.MERGE_BASE, processes);

	const deepenStep = initialDepth;
	let parentDeepenTotal = 0;
	let workingDeepenTotal = 0;

	for (let attempt = 0; attempt < MAX_MERGE_BASE_DEEPEN_ATTEMPTS; attempt++) {
		const mergeBaseSha = computeMergeBase(parent, working);

		if (mergeBaseSha && isCommitReachable(mergeBaseSha) && validatesHistoricalFork(parent, working, mergeBaseSha)) {
			logger(`Merge-base commit: ${mergeBaseSha} (found on attempt ${attempt + 1})`);
			endWatch(RESULT_INFO.ADDITIONAL_INFORMATION.MERGE_BASE, processes);
			logWorkflowStepDone(3, 'Find diff baseline');
			return mergeBaseSha;
		}

		if (parentDeepenTotal < MAX_MERGE_BASE_FETCH_DEPTH) {
			logger(`Deepening origin/${parent} by ${deepenStep} (total parent deepen: ${parentDeepenTotal + deepenStep})`);
			await fetchDeepenBranch(parent, deepenStep);
			parentDeepenTotal += deepenStep;
			continue;
		}

		if (workingDeepenTotal < MAX_MERGE_BASE_FETCH_DEPTH) {
			logger(`Deepening origin/${working} by ${deepenStep} (total working deepen: ${workingDeepenTotal + deepenStep})`);
			await fetchDeepenBranch(working, deepenStep);
			workingDeepenTotal += deepenStep;
			continue;
		}

		break;
	}

	endWatch(RESULT_INFO.ADDITIONAL_INFORMATION.MERGE_BASE, processes);
	throw new Error(
		`Could not resolve merge-base between '${parent}' and '${working}' within shallow depth ` +
			`(max ${MAX_MERGE_BASE_FETCH_DEPTH} per branch). Increase gitDepth or verify branch relationship.`
	);
}

async function validateWorkingBranchFromParent(parent, working) {
	await resolveMergeBaseWithValidation(parent, working, GIT_DEPTH);
}

async function getMergeBase(parent, working) {
	return resolveMergeBaseWithValidation(parent, working, GIT_DEPTH);
}

function computeMergeBase(parent, working) {
	try {
		return child_process
			.execFileSync('git', ['merge-base', `origin/${parent}`, `origin/${working}`], {
				cwd: TARGET_DIRECTORY,
				encoding: 'utf8',
				stdio: ['ignore', 'pipe', 'pipe']
			})
			.trim();
	} catch {
		return '';
	}
}

function isCommitReachable(sha) {
	try {
		child_process.execFileSync('git', ['cat-file', '-e', `${sha}^{commit}`], {
			cwd: TARGET_DIRECTORY,
			stdio: 'pipe'
		});
		return true;
	} catch {
		return false;
	}
}

function validatesHistoricalFork(parent, working, mergeBaseSha) {
	return isAncestorCommit(mergeBaseSha, `origin/${parent}`) && isAncestorCommit(mergeBaseSha, `origin/${working}`);
}

function isAncestorCommit(ancestorSha, descendantRef) {
	try {
		child_process.execFileSync('git', ['merge-base', '--is-ancestor', ancestorSha, descendantRef], {
			cwd: TARGET_DIRECTORY,
			stdio: 'pipe'
		});
		return true;
	} catch {
		return false;
	}
}

async function fetchDeepenBranch(branch, deepenBy) {
	await executeCommand(
		`copado-git-get -g "git fetch origin ${branch} --deepen=${deepenBy}"`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE,
		true
	);
}

// =============================================================================
// STEP 5 – GIT DIFF → RAW FILE LIST
// =============================================================================

async function getDiffFileList(divergenceSha, working) {
	logWorkflowStep(4, 'List changed files', `Diffing baseline → "${working}"`, true);
	startWatch(RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_DIFF, processes);

	const rawDiff = await executeCommand(
		`git diff --name-status --diff-filter=ACMRTD ${divergenceSha}...origin/${working}`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_DIFF,
		false
	);

	endWatch(RESULT_INFO.ADDITIONAL_INFORMATION.GIT_DIFF, processes);

	const files = parseDiffNameStatus(rawDiff);

	// Same upload path as ResultViewer.json: uploadFileAtPath (no --name) and non-empty file body.
	fs.writeFileSync(DIFF_FILE_LIST_PATH, files.all.join('\n') || '\n');
	await uploadFileAtPath(DIFF_FILE_LIST_PATH);

	logWorkflowStepDone(4, 'List changed files');
	return files;
}

function parseDiffNameStatus(rawDiff) {
	const addOrModify = new Set();
	const deleteFiles = new Set();

	rawDiff
		.split('\n')
		.map(line => line.trim())
		.filter(line => line.length > 0)
		.forEach(line => {
			const parts = line.split(/\t+/);
			const status = parts[0];

			if (status === PORCELAIN_STATUS.DELETED) {
				deleteFiles.add(parts[1]);
			} else if (status?.startsWith('R')) {
				if (parts[1]) deleteFiles.add(parts[1]);
				if (parts[2]) addOrModify.add(parts[2]);
			} else {
				addOrModify.add(parts[parts.length - 1]);
			}
		});

	return {
		addOrModify: [...addOrModify],
		delete: [...deleteFiles],
		all: [...new Set([...addOrModify, ...deleteFiles])]
	};
}

// =============================================================================
// STEPS 6-7 – RESOLVE METADATA FROM DIFF (enricher --changefile)
// =============================================================================

async function resolveMetadataFromDiffFiles(diffChanges, divergenceSha) {
	logWorkflowStep(
		5,
		'Identify metadata components',
		'Mapping file paths to Salesforce metadata types and API names',
		true
	);
	startWatch(RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE, RESULT_INFO.ADDITIONAL_INFORMATION.ENRICHER_SERVICE, processes);

	const existingFiles = diffChanges.addOrModify.filter(filePath => fs.existsSync(path.join(TARGET_DIRECTORY, filePath)));
	const deletedFiles = restoreDeletedMetadataFiles(diffChanges.delete, divergenceSha);

	if (!existingFiles.length && !deletedFiles.length) {
		endWatch(RESULT_INFO.ADDITIONAL_INFORMATION.ENRICHER_SERVICE, processes);
		logWorkflowStepDone(5, 'Identify metadata components');
		logger('No metadata files to resolve in the workspace');
		return { changeList: [], metadataFiles: [] };
	}

	let addChanges = { changeList: [], metadataFiles: [] };
	if (existingFiles.length) {
		fs.writeFileSync(DIFF_CHANGE_FILE_PATH, existingFiles.join('\n'));
		await enrichDiffFilePaths(TARGET_DIRECTORY, DIFF_CHANGE_FILE_PATH, DIFF_CHANGE_ENRICHED_PATH);
		addChanges = parseEnrichedDiffChanges(DIFF_CHANGE_ENRICHED_PATH, ACTIONS.ADD, TARGET_DIRECTORY);
	}

	let deleteChanges = { changeList: [], metadataFiles: [] };
	if (deletedFiles.length) {
		fs.writeFileSync(DIFF_DELETE_CHANGE_FILE_PATH, deletedFiles.join('\n'));
		await enrichDiffFilePaths(DELETED_METADATA_DIRECTORY, DIFF_DELETE_CHANGE_FILE_PATH, DIFF_DELETE_CHANGE_ENRICHED_PATH);
		deleteChanges = parseEnrichedDiffChanges(DIFF_DELETE_CHANGE_ENRICHED_PATH, ACTIONS.DELETE, DELETED_METADATA_DIRECTORY);
	}

	const changeList = dedupeChanges([...addChanges.changeList, ...deleteChanges.changeList]);
	const metadataFiles = addChanges.metadataFiles;

	endWatch(RESULT_INFO.ADDITIONAL_INFORMATION.ENRICHER_SERVICE, processes);
	logger(`Resolved ${changeList.length} unique metadata component(s) for Copado commit`);
	logWorkflowStepDone(5, 'Identify metadata components');
	return { changeList, metadataFiles };
}

async function enrichDiffFilePaths(repoPath, changeFilePath, outputPath) {
	asyncCopadoLogMessage('Identifying changed metadata components');
	const cmd = `enricher --repo '${repoPath}/' --changefile '${changeFilePath}' --out '${outputPath}' --operation COMMIT '--handleLabels'`;
	await executeCommand(cmd, RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE, RESULT_INFO.ADDITIONAL_INFORMATION.ENRICHER_SERVICE, true);
}

function restoreDeletedMetadataFiles(deletedFiles, divergenceSha) {
	if (!deletedFiles.length) {
		return [];
	}

	fs.rmSync(DELETED_METADATA_DIRECTORY, { recursive: true, force: true });
	fs.mkdirSync(DELETED_METADATA_DIRECTORY, { recursive: true });
	if (!restoreFileFromGit(divergenceSha, 'sfdx-project.json', DELETED_METADATA_DIRECTORY, true)) {
		copyCurrentProjectConfig(DELETED_METADATA_DIRECTORY);
	}

	const restoredFiles = [];
	for (const filePath of deletedFiles) {
		if (restoreFileFromGit(divergenceSha, filePath, DELETED_METADATA_DIRECTORY, false)) {
			restoredFiles.push(filePath);
		}
	}

	const failedRestores = deletedFiles.filter(filePath => !restoredFiles.includes(filePath));
	if (failedRestores.length) {
		throw new Error(`Could not restore ${failedRestores.length} deleted file(s) from merge-base ${divergenceSha}: ${failedRestores.join(', ')}`);
	}

	return restoredFiles;
}

function copyCurrentProjectConfig(targetRoot) {
	const currentProjectConfig = path.join(TARGET_DIRECTORY, 'sfdx-project.json');
	if (!fs.existsSync(currentProjectConfig)) {
		return;
	}

	fs.copyFileSync(currentProjectConfig, path.join(targetRoot, 'sfdx-project.json'));
}

function restoreFileFromGit(ref, filePath, targetRoot, allowMissing) {
	try {
		const fileContent = child_process.execFileSync('git', ['show', `${ref}:${filePath}`], { cwd: TARGET_DIRECTORY });
		const targetPath = path.join(targetRoot, filePath);
		fs.mkdirSync(path.dirname(targetPath), { recursive: true });
		fs.writeFileSync(targetPath, fileContent);
		return true;
	} catch (error) {
		if (!allowMissing) {
			logger(`WARN: Could not restore deleted path ${filePath} from ${ref}: ${error.message}`);
		}
		return false;
	}
}

function parseEnrichedDiffChanges(enrichedJsonPath, action = ACTIONS.ADD, repoRoot = TARGET_DIRECTORY) {
	if (!fs.existsSync(enrichedJsonPath)) {
		return { changeList: [], metadataFiles: [] };
	}

	const items = JSON.parse(fs.readFileSync(enrichedJsonPath, 'utf8'));
	const seen = new Set();
	const changeList = [];
	const metadataFiles = new Set();

	for (const item of items) {
		if (!item?.n || !item?.t) {
			continue;
		}

		const key = `${item.t}:${item.n}`;
		if (!seen.has(key)) {
			seen.add(key);
			changeList.push({
				n: item.n,
				t: item.t,
				a: action,
				c: CATEGORY.SFDX
			});
		}

		for (const filePath of extractFilePathsFromEnrichedItem(item)) {
			const relativePath = toRepoRelativePath(filePath, repoRoot);
			if (relativePath) {
				metadataFiles.add(relativePath);
			}
		}
	}

	return { changeList, metadataFiles: [...metadataFiles] };
}

function dedupeChanges(changes) {
	const byMetadata = new Map();

	for (const change of changes) {
		const key = `${change.t}:${change.n}`;
		const existingChange = byMetadata.get(key);
		if (!existingChange || (existingChange.a === ACTIONS.DELETE && change.a === ACTIONS.ADD)) {
			byMetadata.set(key, change);
		}
	}

	return [...byMetadata.values()];
}

function extractFilePathsFromEnrichedItem(item) {
	const paths = [];

	if (item.j) {
		try {
			const parsed = typeof item.j === 'string' ? JSON.parse(item.j) : item.j;
			const filePath = parsed?.filePath;
			if (filePath) {
				paths.push(...(Array.isArray(filePath) ? filePath : [filePath]));
			}
		} catch (error) {
			logger(`WARN: Could not parse enricher file paths for ${item.n}: ${error.message}`);
		}
	}

	if (item.m) {
		paths.push(item.m);
	}

	return paths;
}

function toRepoRelativePath(filePath, repoRoot = TARGET_DIRECTORY) {
	if (!filePath) {
		return '';
	}

	let relativePath = filePath.replace(/\\/g, '/');
	const repoPrefix = `${repoRoot.replace(/\/$/, '')}/`;

	if (relativePath.startsWith(repoPrefix)) {
		relativePath = relativePath.slice(repoPrefix.length);
	}

	return relativePath.replace(/^\/+/, '');
}

// =============================================================================
// STEP 8 – ENRICHER
// =============================================================================

async function enrichChangeList(filePath) {
	logWorkflowStep(5, 'Resolve file paths', 'Linking metadata components to their repository files', true);
	asyncCopadoLogMessage('Resolving file paths for commit staging');

	const cmd = `enricher -p ${filePath} --repo ${TARGET_DIRECTORY}/ --quick true --operation COMMIT '--handleLabels'`;
	await executeCommand(cmd, RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE, RESULT_INFO.ADDITIONAL_INFORMATION.ENRICHER_SERVICE);

	logWorkflowStepDone(5, 'Resolve file paths');
}

// =============================================================================
// STEP 9 – VAR REPLACE + FIND & REPLACE
// =============================================================================

function varReplace(sourceEnvJson, filesToInclude) {
	if (sourceEnvJson && JSON.parse(sourceEnvJson)?.length) {
		const varreplaceCommand = `varreplace '${sourceEnvJson}' '${TARGET_DIRECTORY}' ${
			filesToInclude ? '--valuename=true --include=' + filesToInclude : ''
		} || exit 1`;
		asyncCopadoLogMessage('Applying env variable replacements');
		return executeCommand(
			varreplaceCommand,
			RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE,
			RESULT_INFO.ADDITIONAL_INFORMATION.ENV_VARIABLE_REPLACEMENT
		);
	}
	return Promise.resolve();
}

function findAndReplace(findAndReplaceFileId, featureBranch, filesInScope) {
	const PATH_TO_YAML = `${TEMP_DIRECTORY}/${COPADO_YML}`;
	if (findAndReplaceFileId) {
		asyncCopadoLogMessage('Applying find-and-replace rules');
		const cmd = `
        ${downloadFile(findAndReplaceFileId, `${TEMP_DIRECTORY}/`, COPADO_YML)} || exit 1
        yamlreplace "${PATH_TO_YAML}" "${TARGET_DIRECTORY}" -b "${featureBranch}" ${filesInScope ? '--include=' + filesInScope : ''}`;
		return executeCommand(cmd, RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE, RESULT_INFO.ADDITIONAL_INFORMATION.GLOBAL_FIND_AND_REPLACE);
	}
	return Promise.resolve();
}

// =============================================================================
// STEP 10 – METADATA PROCESSOR
// =============================================================================

async function processMetadata() {
	logWorkflowStep(
		5,
		'Post-process metadata',
		'Handling custom labels, destructive manifests, and other metadata quirks',
		true
	);
	asyncCopadoLogMessage('Post-processing metadata files');

	const cmd = `metadata-processor "${COMMIT_CHANGES_FILE_PATH}" "${TARGET_DIRECTORY}" -o COMMIT --handleLabels`;
	await executeCommand(cmd, RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE, RESULT_INFO.ADDITIONAL_INFORMATION.METADATA_PROCESSOR);

	logWorkflowStepDone(5, 'Post-process metadata');
}

// =============================================================================
// STEPS 11-14 – GIT STATUS → ADD → COMMIT → PUSH → SAVE ID → MERGE BACK
// =============================================================================

async function commitAndUpdateEnvironmentBranches(gitDepth) {
	logWorkflowStep(6, 'Commit and push user story branch', `Staging files, committing on "${FEATURE_BRANCH}", and pushing to remote`, true);
	startWatch(RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_MERGE_PUSH_FEATURE_BRANCH, processes);

	const resultData = enrichResultDataWithArtifactContext({});
	const hasCopadoMetadataChanges = hasCommitChangesFileEntries();

	// Step 11: git status → check for real changes
	const gitStatus = await executeCommand(
		'git status --porcelain',
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_STATUS,
		true
	);

	fs.writeFileSync(GIT_STATUS_FILE_PATH, gitStatus);

	const hasChanges = hasRelevantGitChanges(gitStatus);

	if (!hasChanges) {
		if (hasCopadoMetadataChanges) {
			resultData.commitId = await getCurrentCommitId();
			populateResultViewer(
				RESULT_INFO.LEVEL.INFO,
				RESULT_INFO.CATEGORY.COMMIT_INFO,
				'',
				`No workspace changes to commit; using existing feature branch HEAD ${resultData.commitId} for Copado commit details`
			);
			asyncCopadoLogMessage('Already committed — recording existing commit');
		} else {
			resultData.status = 'No Changes';
			populateResultViewer(RESULT_INFO.LEVEL.INFO, RESULT_INFO.CATEGORY.COMMIT_INFO, '', 'No Changes');
			asyncCopadoLogMessage('No metadata changes — pushing branch');
		}
	} else {
		const filesToStage = getFilePathsFromStatus(gitStatus);
		logger(`Staging ${filesToStage.length} path(s) for commit on ${FEATURE_BRANCH}`);
		await gitCommitFiles(getCommitMessage(), FEATURE_BRANCH, filesToStage);
		resultData.commitId = await getCurrentCommitId();
	}

	// Step 12b: always push feature branch (create remote branch or update existing ref)
	await gitPush(FEATURE_BRANCH);

	if (!hasChanges && !hasCopadoMetadataChanges) {
		await executeCommand(
			`copado -p "No metadata changes detected" -r '${JSON.stringify(resultData)}'`,
			RESULT_INFO.CATEGORY.COPADO_SERVICE,
			'',
			true
		);
	}

	const progressStatus = hasChanges || hasCopadoMetadataChanges
		? 'Commit Completed, Environment branches will be merged in the background'
		: 'No file changes; feature branch pushed to remote and environment branch will be merged in the background';

	await finishCommit(true, true, progressStatus, resultData);

	logWorkflowStepDone(6, 'Commit and push user story branch');

	// Step 7: merge feature branch into environmentBranch
	await executeAfterCommitOperations(environmentBranch, FEATURE_BRANCH, gitDepth, 0);

	endWatch(RESULT_INFO.ADDITIONAL_INFORMATION.GIT_MERGE_PUSH_FEATURE_BRANCH, processes);
}

// =============================================================================
// GIT HELPERS
// =============================================================================

/**
 * Returns true when git status has at least one non-SF CLI config change.
 * Ignores .sf/ and .sfdx/ noise.
 */
function hasRelevantGitChanges(gitStatus) {
	if (!gitStatus?.trim()) return false;
	const IGNORED_PREFIXES = ['.sf/', '.sfdx/'];
	const isIgnoredPath = p => IGNORED_PREFIXES.some(prefix => p.startsWith(prefix));
	const parseStatusPath = line => line.trim().replace(/^[A-Z?]{1,2}\s+/, '');
	return gitStatus
		.split('\n')
		.filter(Boolean)
		.map(parseStatusPath)
		.some(p => !isIgnoredPath(p));
}

function hasCommitChangesFileEntries() {
	if (!fs.existsSync(COMMIT_CHANGES_FILE_PATH)) {
		return false;
	}
	try {
		const changes = JSON.parse(fs.readFileSync(COMMIT_CHANGES_FILE_PATH, 'utf8'));
		return Array.isArray(changes) && changes.length > 0;
	} catch (error) {
		logger(`WARN: Could not inspect ${COMMIT_CHANGES_FILE_PATH}: ${error.message}`);
		return false;
	}
}

async function getCurrentCommitId() {
	return (await executeCommand('git rev-parse HEAD', RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_STATUS, true)).trim();
}

/**
 * Extracts file paths from `git status --porcelain` output.
 */
function getFilePathsFromStatus(statusOutput) {
	return statusOutput
		.split('\n')
		.map(l => l.trim())
		.filter(l => l.length > 0)
		.map(line => {
			const parts = line.split(/\s+/);
			return parts[parts.length - 1];
		});
}

/**
 * git add (chunked) + git commit.
 * Mirrors commit function's gitCommit() exactly.
 */
async function gitCommitFiles(message, branchName, filePaths, allowCommitWithNoChanges) {
	message = message.replace(/[`"$\\]/g, '\\$&');
	let gitAddCmd = '';
	asyncCopadoLogMessage(`Committing on "${branchName}"`);

	if (filePaths?.length) {
		try {
			await executeCommandinChunks(filePaths, chunkSize, 'git add REPLACE_VALUE', {
				category: RESULT_INFO.CATEGORY.GIT_SERVICE,
				additionalInfo: RESULT_INFO.ADDITIONAL_INFORMATION.GIT_ADD
			});
		} catch (error) {
			logger('Re-trying staging using git add . as chunking failed: ' + error);
			gitAddCmd = 'git add . || exit 1';
		}
	} else {
		gitAddCmd = 'git add . || exit 1';
	}

	const commitCmd = `
        ${gitAddCmd}
        git commit -m "${message}" ${allowCommitWithNoChanges ? '|| true' : ''}`;
	await executeCommand(commitCmd, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_COMMIT, true);
}

async function gitPush(branchName) {
	asyncCopadoLogMessage(`Pushing "${branchName}" to remote`);
	const cmd = `copado-git-get -g "git push origin ${branchName}"`;
	const MAX_PUSH_ATTEMPTS = 3;
	const RETRY_DELAY_MS = 4000;
	let lastError;
	for (let attempt = 1; attempt <= MAX_PUSH_ATTEMPTS; attempt++) {
		try {
			await executeCommand(cmd, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_PUSH, true);
			return;
		} catch (error) {
			lastError = error;
			if (!isTransientGitPushError(error) || attempt === MAX_PUSH_ATTEMPTS) {
				throw error;
			}
			const waitMs = RETRY_DELAY_MS * attempt;
			logger(
				`Git push to ${branchName} failed with a transient error (attempt ${attempt}/${MAX_PUSH_ATTEMPTS}). Retrying in ${waitMs / 1000}s.`
			);
			await sleep(waitMs);
		}
	}
	throw lastError;
}

function isTransientGitPushError(error) {
	const message = (error && (error.message || error.toString())) || '';
	return (
		/fatal error in commit_refs/i.test(message) ||
		/remote rejected/i.test(message) ||
		/RPC failed/i.test(message) ||
		/early EOF/i.test(message) ||
		/HTTP 5\d\d/i.test(message) ||
		/Could not resolve host/i.test(message) ||
		/Connection (reset|refused|timed out)/i.test(message)
	);
}

function sleep(ms) {
	return new Promise(resolve => setTimeout(resolve, ms));
}

async function configureGit(gitEmail, gitName) {
	const cmd = `
        git config feature.manyFiles true || exit 1
        git update-index --index-version 4 || exit 1
        git config --local user.email "${gitEmail}" || exit 1
        git config --local user.name "${gitName}" || exit 1
        git config --global diff.renames false || exit 1
        git config --global merge.renames false || exit 1
        git config --global status.renames false || exit 1
        git config --global core.quotePath false
    `;
	await executeCommand(cmd, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CONFIG, true);
}

function fetchCheckoutBranch(branch, gitDepth, forceCreate) {
	return (
		`( copado-git-get -g "git fetch origin ${branch} --depth ${gitDepth}" && git checkout ${branch} )` +
		(forceCreate ? ` || git checkout -b ${branch}` : '')
	);
}

function changeWorkingDirectory(dir) {
	process.chdir(dir);
}

// =============================================================================
// STEP 14 – MERGE FEATURE BRANCH INTO ENVIRONMENT BRANCH
// =============================================================================

async function executeAfterCommitOperations(targetEnvironmentBranch, featureBranch, gitDepth, numberOfRetries) {
	logWorkflowStep(7, `Merge into ${targetEnvironmentBranch}`, `Integrating "${featureBranch}" into "${targetEnvironmentBranch}"`, true);
	try {
		await executeCommand(
			`git reset --hard || true
             git clean -fd || true`,
			RESULT_INFO.CATEGORY.GIT_SERVICE,
			RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLEAN,
			true
		);
		await executeCommand(
			fetchCheckoutBranch(targetEnvironmentBranch, gitDepth, false),
			RESULT_INFO.CATEGORY.GIT_SERVICE,
			RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CHECKOUT,
			true
		);
		await mergeFeatureBranchInSource(featureBranch, targetEnvironmentBranch);
		await checkSFDXProjectJson(targetEnvironmentBranch, sourceApiVersion);
		await gitPush(targetEnvironmentBranch);
		endWatch(RESULT_INFO.ADDITIONAL_INFORMATION.GIT_MERGE_PUSH_FEATURE_BRANCH, processes);
	} catch (error) {
		if (numberOfRetries < 1) {
			await executeAfterCommitOperations(targetEnvironmentBranch, featureBranch, gitDepth, numberOfRetries + 1);
		} else {
			await executeCommand(getErrorCmdString(error.message));
		}
	}
	logWorkflowStepDone(7, `Merge into ${targetEnvironmentBranch}`);
}

async function mergeFeatureBranchInSource(featureBranch, targetEnvironmentBranch) {
	if (!targetEnvironmentBranch) {
		throw new Error('No environment branch provided');
	}

	try {
		const mergeCmd = `git merge "${featureBranch}" -Xignore-space-change`;
		await executeCommand(mergeCmd, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_MERGE, true);
	} catch (error) {
		await resolveMergeConflictsIfPresent(error);
	}

	await gitCommitFiles(
		`Merging ${featureBranch} into ${targetEnvironmentBranch} after auto conflict resolution`,
		targetEnvironmentBranch,
		undefined,
		true
	);
}

async function resolveMergeConflictsIfPresent(mergeError) {
	const gitStatus = await executeCommand(
		'git status --porcelain=v1',
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_STATUS,
		true
	);
	logger(gitStatus);
	fs.writeFileSync(GIT_STATUS_FILE_PATH, gitStatus);

	if (!hasConflict()) {
		throw mergeError;
	}

	fs.writeFileSync(OUTPUT_JSON_FILE_PATH, '');
	asyncCopadoLogMessage('Auto-resolving merge conflict');
	await executeCommand(
		`copado-merge ${TARGET_DIRECTORY} ${COMMIT_CHANGES_FILE_PATH} -p ${GIT_STATUS_FILE_PATH} -t sfdx -c --out ${TEMP_DIRECTORY}/`,
		RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE,
		'Copado Merge'
	);
}

async function checkSFDXProjectJson(branchName, apiVersion) {
	const sfdxProjectJsonPath = `${TARGET_DIRECTORY}/sfdx-project.json`;
	if (!fs.existsSync(sfdxProjectJsonPath)) {
		throw new Error(
			`Invalid configuration in ${branchName}. sfdx-project.json is invalid or missing at project root. Copado Commit and Deploy operations are required to run from within a valid sfdx project.`
		);
	}

	const fileContent = JSON.parse(fs.readFileSync(sfdxProjectJsonPath, 'utf8'));
	if (fileContent.sourceApiVersion === apiVersion) {
		return;
	}

	const updateMessage = `Updated sourceApiVersion from ${fileContent.sourceApiVersion} to ${apiVersion} in sfdx-project.json to align the commit, promote and deploy operations with the latest supported api version of Copado`;
	fileContent.sourceApiVersion = apiVersion;
	fs.writeFileSync(sfdxProjectJsonPath, JSON.stringify(fileContent, null, 2));
	await gitCommitFiles(updateMessage, branchName, ['sfdx-project.json']);
}

function hasConflict() {
	let conflict = false;
	const gitStatus = fs.readFileSync(GIT_STATUS_FILE_PATH, 'utf-8');
	if (gitStatus) {
		const porcelainStatus = gitStatus.split('\n').map(str => str.split(' ')?.[0]);
		conflict = porcelainStatus.some(status => {
			if (
				(status[0] && status[1] && status[0] === PORCELAIN_STATUS.ADDED && status[1] === PORCELAIN_STATUS.ADDED) ||
				(status[0] === PORCELAIN_STATUS.DELETED && status[1] === PORCELAIN_STATUS.DELETED)
			)
				return true;
			return status[0] === PORCELAIN_STATUS.UNMERGED || status[1] === PORCELAIN_STATUS.UNMERGED;
		});
	}
	return conflict;
}

// =============================================================================
// EARLY FINISH / RESULT HELPERS
// =============================================================================

function finishCommit(isFinished, isSuccess, progressStatus, resultData) {
	logger('START Early Finish Commit');
	return new Promise(resolve => {
		const CF_SF_SESSIONID = process.env.CF_SF_SESSIONID;
		const CF_SF_ENDPOINT = process.env.CF_SF_ENDPOINT.replace('https://', '');

		const body = JSON.stringify({
			result_id: process.env.CF_RESULTID,
			is_finished: isFinished,
			is_success: isSuccess,
			status: progressStatus,
			result_data: JSON.stringify(resultData)
		});

		const options = {
			hostname: CF_SF_ENDPOINT,
			path: '/services/apexrest/copado/FunctionWebEvent',
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Accept: 'application/json',
				'Content-Length': Buffer.byteLength(body),
				Authorization: `Bearer ${CF_SF_SESSIONID}`
			}
		};

		const req = https.request(options, res => {
			res.on('data', () => {});
			res.on('end', async () => {
				logger(`Status Code: ${res.statusCode}`);
				if (res.statusCode == 200) {
					logger('END Early Finish Commit');
					resolve(body);
				} else {
					await updateResultWithCommitDetails(resultData);
					logger('END Early Finish Commit');
					resolve(body);
				}
			});
		});

		req.on('error', async error => {
			await updateResultWithCommitDetails(resultData);
			logger(`error: ${error}`);
			logger('END Early Finish Commit');
			resolve(body);
		});

		req.write(body);
		req.end();
	});
}

async function updateResultWithCommitDetails(resultData) {
	const summary = resultData?.status ? `Status: ${resultData.status}` : 'Saving result details';
	populateResultViewer(RESULT_INFO.LEVEL.INFO, RESULT_INFO.CATEGORY.COMMIT_INFO, '', summary);
	await executeCommand(`copado -p 'Saving commit result' --result-data '${JSON.stringify(resultData)}'`);
}

async function copyVlocityFilesIfPresent(sourcePath) {
	if (!sourcePath || !fs.existsSync(sourcePath)) {
		return;
	}

	await executeCommand(
		`cp -R "${sourcePath}" "${TARGET_DIRECTORY}"`,
		RESULT_INFO.CATEGORY.FILE_SYSTEM,
		RESULT_INFO.ADDITIONAL_INFORMATION.COPY_FILES
	);
}

function reportNoChanges(reason) {
	logger(`${reason}`);
	populateResultViewer(RESULT_INFO.LEVEL.INFO, RESULT_INFO.CATEGORY.COMMIT_INFO, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_STATUS, reason);
	if (fs.existsSync(COMMIT_CHANGES_FILE_PATH)) {
		fs.rmSync(COMMIT_CHANGES_FILE_PATH);
	}
	throw new NoChangesEarlyExit(reason);
}

// =============================================================================
// COPADO CLI HELPERS
// =============================================================================

function getErrorCmdString(error, userFacing = false) {
	const text = error?.trim()?.substring(0, 32760) || '';
	if (userFacing) {
		return `copado -p "Error" -e ${JSON.stringify(text)}`;
	}
	const suffix = 'Please check the logs for details.';
	return `copado -p "Error" -e ${JSON.stringify(text + '; ' + suffix)}`;
}

function uploadFile(filePath, name) {
	return executeCommand(
		`copado --uploadfile ${filePath} ${name ? '--name ' + name : ''}`,
		RESULT_INFO.CATEGORY.COPADO_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.UPLOAD_FILES
	);
}

function uploadFileAtPath(filePath) {
	return executeCommand(`copado --uploadfile ${filePath}`, RESULT_INFO.CATEGORY.COPADO_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.UPLOAD_FILES);
}

async function uploadCopadoCommitChangesToUserStory() {
	if (!USER_STORY_ID || !fs.existsSync(COMMIT_CHANGES_FILE_PATH)) {
		return;
	}

	let currentChanges = [];
	try {
		currentChanges = JSON.parse(fs.readFileSync(COMMIT_CHANGES_FILE_PATH, 'utf8'));
	} catch (error) {
		logger(`WARN: Could not read current change list for the attachment: ${error.message}`);
		return;
	}

	// Fetch any existing "Copado Commit Changes" already attached to the user story. We always need
	// the document ids so stale attachments can be removed after the new upload.
	const { changes: existingChanges, documentIds: existingDocumentIds } = await fetchExistingCommitChanges();

	// When the feature branch is recreated, it is rebuilt from scratch off the base branch tip, so
	// the current diff is the authoritative snapshot of the user story's net changes. Additively
	// merging with a previous run would resurrect stale entries for metadata that has since been
	// removed (e.g. a component added then deleted within the release). In that case, replace the
	// attachment with the current diff instead of unioning it with history.
	let mergedChanges;
	if (SHOULD_RECREATE_FEATURE_BRANCH) {
		mergedChanges = currentChanges;
		if (existingChanges.length) {
			logger(
				`Feature branch recreated — replacing ${existingChanges.length} existing change(s) with the ${currentChanges.length} from the current diff in ${COPADO_COMMIT_CHANGES_FILE_NAME}.`
			);
		}
	} else {
		// The newest entry wins per type:name key, keeping the attachment cumulative across runs.
		mergedChanges = mergeChangeLists(existingChanges, currentChanges);
		if (existingChanges.length) {
			logger(
				`Merged ${currentChanges.length} new change(s) with ${existingChanges.length} existing — ${mergedChanges.length} total in ${COPADO_COMMIT_CHANGES_FILE_NAME}.`
			);
		}
	}

	// Write to a dedicated file so COMMIT_CHANGES_FILE_PATH (the current diff) keeps flowing through
	// enricher / metadata-processor / git untouched — only the uploaded attachment is cumulative.
	const mergedPath = `${TEMP_DIRECTORY}/copadoCommitChanges.json`;
	fs.writeFileSync(mergedPath, JSON.stringify(mergedChanges, null, 2));

	asyncCopadoLogMessage(`Attaching change list to ${USER_STORY_NAME || USER_STORY_ID}`);
	// `copado --uploadfile` always creates a NEW ContentDocument; it does not version an existing
	// attachment by title. So we upload the merged file first and then delete the previous
	// document(s) to guarantee a single "Copado Commit Changes" attachment on the user story.
	await executeCommand(
		`copado --uploadfile "${mergedPath}" --name "${COPADO_COMMIT_CHANGES_FILE_NAME}" --parentid "${USER_STORY_ID}"`,
		RESULT_INFO.CATEGORY.COPADO_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.UPLOAD_FILES
	);
	await deleteCommitChangesAttachments(existingDocumentIds);
}

/**
 * Deletes the previous "Copado Commit Changes" ContentDocuments (captured before the new upload) so
 * only the freshly uploaded attachment remains. Best-effort: failures are logged but never break
 * the commit flow.
 */
async function deleteCommitChangesAttachments(documentIds) {
	if (!documentIds || !documentIds.length) {
		return;
	}
	const apiVersion = sourceApiVersion || API_VERSION || '60.0';
	for (const documentId of documentIds) {
		const response = await copadoOrgDelete(`/services/data/v${apiVersion}/sobjects/ContentDocument/${documentId}`);
		if (!response || (response.statusCode !== 204 && response.statusCode !== 200)) {
			logger(`WARN: Could not delete previous ${COPADO_COMMIT_CHANGES_FILE_NAME} attachment ${documentId}.`);
		}
	}
}

/**
 * Merges two Copado change lists keyed by `${t}:${n}`. The newest entry always wins, so an Add can
 * later be superseded by a Delete (and vice versa). Existing-only keys are retained; new keys are
 * appended. Returns a plain array preserving existing order with new keys at the end.
 */
function mergeChangeLists(existingChanges, currentChanges) {
	const byKey = new Map();
	for (const change of existingChanges || []) {
		if (change?.t && change?.n) {
			byKey.set(`${change.t}:${change.n}`, change);
		}
	}
	for (const change of currentChanges || []) {
		if (change?.t && change?.n) {
			byKey.set(`${change.t}:${change.n}`, change);
		}
	}
	return [...byKey.values()];
}

/**
 * Reads the existing "Copado Commit Changes" attachment(s) from the user story in the Copado org.
 * Queries ContentDocumentLink by parent + title, then downloads the latest version's VersionData
 * from the most recent document. Returns { changes, documentIds } where documentIds lists every
 * matching ContentDocument so callers can delete stale attachments after re-uploading.
 * Resilient by design: any missing session, failed request, or bad JSON yields an empty result so
 * the commit flow is never broken (e.g. the first run has no attachment yet).
 */
async function fetchExistingCommitChanges() {
	const emptyResult = { changes: [], documentIds: [] };
	if (!USER_STORY_ID || !process.env.CF_SF_SESSIONID || !process.env.CF_SF_ENDPOINT) {
		return emptyResult;
	}

	const apiVersion = sourceApiVersion || API_VERSION || '60.0';
	const soql =
		`SELECT ContentDocumentId, ContentDocument.LatestPublishedVersionId FROM ContentDocumentLink ` +
		`WHERE LinkedEntityId = '${USER_STORY_ID}' AND ContentDocument.Title = '${COPADO_COMMIT_CHANGES_FILE_NAME}' ` +
		`ORDER BY ContentDocument.ContentModifiedDate DESC`;

	const queryResponse = await copadoOrgGet(`/services/data/v${apiVersion}/query?q=${encodeURIComponent(soql)}`);
	if (!queryResponse || queryResponse.statusCode !== 200) {
		logger(`No existing ${COPADO_COMMIT_CHANGES_FILE_NAME} attachment found; starting a fresh change list.`);
		return emptyResult;
	}

	let records;
	try {
		records = JSON.parse(queryResponse.body)?.records || [];
	} catch (error) {
		logger(`WARN: Could not parse ${COPADO_COMMIT_CHANGES_FILE_NAME} query response: ${error.message}`);
		return emptyResult;
	}

	const documentIds = records.map(record => record?.ContentDocumentId).filter(Boolean);
	const versionId = records?.[0]?.ContentDocument?.LatestPublishedVersionId;
	if (!versionId) {
		return { changes: [], documentIds };
	}

	const fileResponse = await copadoOrgGet(`/services/data/v${apiVersion}/sobjects/ContentVersion/${versionId}/VersionData`);
	if (!fileResponse || fileResponse.statusCode !== 200) {
		logger(`WARN: Could not download existing ${COPADO_COMMIT_CHANGES_FILE_NAME} content; starting a fresh change list.`);
		return { changes: [], documentIds };
	}

	try {
		const parsed = JSON.parse(fileResponse.body);
		return { changes: Array.isArray(parsed) ? parsed : [], documentIds };
	} catch (error) {
		logger(`WARN: Existing ${COPADO_COMMIT_CHANGES_FILE_NAME} is not valid JSON: ${error.message}`);
		return { changes: [], documentIds };
	}
}

/**
 * Performs an authenticated GET against the Copado platform org using the function's session
 * (CF_SF_SESSIONID / CF_SF_ENDPOINT). Resolves to { statusCode, body } or null on transport error.
 */
function copadoOrgGet(requestPath) {
	return new Promise(resolve => {
		const sessionId = process.env.CF_SF_SESSIONID;
		const endpoint = process.env.CF_SF_ENDPOINT;
		if (!sessionId || !endpoint) {
			resolve(null);
			return;
		}

		const options = {
			hostname: endpoint.replace('https://', ''),
			path: requestPath,
			method: 'GET',
			headers: {
				Authorization: `Bearer ${sessionId}`,
				Accept: 'application/json'
			}
		};

		const req = https.request(options, res => {
			let data = '';
			res.on('data', chunk => (data += chunk));
			res.on('end', () => resolve({ statusCode: res.statusCode, body: data }));
		});

		req.on('error', error => {
			logger(`WARN: Copado org request failed: ${error.message}`);
			resolve(null);
		});

		req.end();
	});
}

/**
 * Performs an authenticated DELETE against the Copado platform org using the function's session
 * (CF_SF_SESSIONID / CF_SF_ENDPOINT). Resolves to { statusCode } or null on transport error.
 */
function copadoOrgDelete(requestPath) {
	return new Promise(resolve => {
		const sessionId = process.env.CF_SF_SESSIONID;
		const endpoint = process.env.CF_SF_ENDPOINT;
		if (!sessionId || !endpoint) {
			resolve(null);
			return;
		}

		const options = {
			hostname: endpoint.replace('https://', ''),
			path: requestPath,
			method: 'DELETE',
			headers: {
				Authorization: `Bearer ${sessionId}`,
				Accept: 'application/json'
			}
		};

		const req = https.request(options, res => {
			res.on('data', () => {});
			res.on('end', () => resolve({ statusCode: res.statusCode }));
		});

		req.on('error', error => {
			logger(`WARN: Copado org request failed: ${error.message}`);
			resolve(null);
		});

		req.end();
	});
}

function uploadResultViewerJson(data, columns, header, headerIcon) {
	const RESULT_VIEWER_JSON_PATH = `${TEMP_DIRECTORY}/ResultViewer.json`;
	const fileContent = { data, columns, header, headerIcon };
	fs.writeFileSync(RESULT_VIEWER_JSON_PATH, JSON.stringify(fileContent, null, 2));
	return uploadFileAtPath(RESULT_VIEWER_JSON_PATH);
}

function downloadFile(fileId, downloadDir, fileName) {
	return `copado --downloadfiles ${fileId} --downloaddir ${downloadDir}${fileName ? ' --name ' + fileName : ''}`;
}

// =============================================================================
// EXECUTE COMMAND (real implementation – mirrors commit function exactly)
// =============================================================================

function getMissingBranchOriginHint(branch) {
	if (branch === baseBranch && baseBranchOrigin) {
		return ` If you need to create it, branch "${branch}" from "${baseBranchOrigin}".`;
	}
	if (branch === FEATURE_BRANCH && baseBranch) {
		return ` If you need to create it, branch "${branch}" from "${baseBranch}".`;
	}
	return '';
}

function humanizeGitError(message, command = '') {
	const text = `${message || ''}\n${command || ''}`;

	const remoteRefMatch = text.match(/couldn't find remote ref\s+(\S+)/i) || text.match(/Remote branch\s+(\S+)\s+not found/i);
	if (remoteRefMatch) {
		const branch = remoteRefMatch[1];
		const branchFromHint = getMissingBranchOriginHint(branch);
		return `Branch "${branch}" was not found on the remote Git repository. Make sure the branch exists on the remote.${branchFromHint}`;
	}

	const pathspecMatch = text.match(/pathspec '([^']+)' did not match/i);
	if (pathspecMatch) {
		const branch = pathspecMatch[1];
		return `Branch "${branch}" is not available in the local Git repository.`;
	}

	if (/Authentication failed|Permission denied \(publickey\)|invalid credentials/i.test(text)) {
		return 'Git authentication failed. Verify the repository credentials configured in Copado can access this repository.';
	}

	if (/repository not found/i.test(text)) {
		return 'The Git repository was not found. Verify the repository URL and credentials configured in Copado.';
	}

	return null;
}

function formatCommandErrorMessage(rawError, command = '') {
	if (!rawError) {
		return { message: '', userFacing: false };
	}
	const lines = rawError
		.split('\n')
		.map(line => line.trim())
		.filter(line => line && !line.includes(COPADO_INFO_PREFIX));

	const finalLine = lines.find(line => /File upload failed after/i.test(line));
	if (finalLine) {
		const finalError = finalLine.match(/Final error:\s*(.+)$/i);
		if (finalError) {
			return { message: summarizeSalesforceApiError(finalError[1]), userFacing: false };
		}
	}

	const sfLines = lines.filter(line => /Salesforce api error/i.test(line));
	if (sfLines.length) {
		return { message: summarizeSalesforceApiError(sfLines[sfLines.length - 1]), userFacing: false };
	}

	const seen = new Set();
	const deduped = [];
	for (const line of lines) {
		if (/^(Traceback|File "|Exception:|raise |\^)/.test(line)) {
			continue;
		}
		const normalized = line.replace(/File upload attempt \d+ failed:\s*/i, '').replace(/Retrying in [\d.]+ seconds.*$/i, '');
		if (!normalized || seen.has(normalized)) {
			continue;
		}
		seen.add(normalized);
		deduped.push(line);
	}
	const cleaned = deduped.join(' ').trim() || rawError.trim();
	const humanized = humanizeGitError(cleaned, command);
	if (humanized) {
		return { message: humanized, userFacing: true };
	}
	return { message: cleaned, userFacing: false };
}

function summarizeSalesforceApiError(text) {
	const statusMatch = text.match(/Salesforce api error:\s*(\d+)/i);
	const urlMatch = text.match(/when calling\s+(https?:\/\/\S+)/i);
	const jsonBlobMatch = text.match(/:\s*b?'(\[.*\])'/s) || text.match(/:\s*(\[.*\])\s*$/s);

	if (jsonBlobMatch) {
		try {
			const parsed = JSON.parse(jsonBlobMatch[1].replace(/\\"/g, '"'));
			const messages = [...new Set(parsed.map(entry => entry.message).filter(Boolean))];
			const parts = [];
			if (statusMatch) {
				parts.push(`HTTP ${statusMatch[1]}`);
			}
			if (messages.length) {
				parts.push(messages.join('; '));
			}
			if (urlMatch) {
				parts.push(urlMatch[1]);
			}
			return parts.join(' — ');
		} catch (_) {
			// fall through to plain text cleanup
		}
	}

	return text
		.replace(/CopadoFunction (WARNING|ERROR)\s*/gi, '')
		.replace(/File upload attempt \d+ failed:\s*/gi, '')
		.replace(/Retrying in [\d.]+ seconds\.\.\. \(attempt \d+\/\d+\)/gi, '')
		.replace(/\s+/g, ' ')
		.trim();
}

function executeCommand(command, category, additionalInfo, disableMetrics, hasJsonResponse, disableLogs, options) {
	logger(`===> ${command}`);
	return new Promise((resolve, reject) => {
		let output = '',
			error = '';
		if (!disableMetrics) {
			startWatch(category, additionalInfo, processes);
		}
		const childProcess = child_process.spawn(command, [], options ? options : { shell: true });

		childProcess.stdout.on('data', data => {
			const outputStream = data?.toString();
			if (!disableLogs && outputStream) {
				logger(outputStream);
			}
			output += outputStream;
		});

		childProcess.stderr.on('data', data => {
			const errorStream = data?.toString();
			if (errorStream) {
				logger(errorStream);
				error += errorStream;
			}
		});

		childProcess.on('close', code => {
			if (code !== 0) {
				let errorMessage = '';
				if (hasJsonResponse) {
					try {
						resolve(JSON.parse(output));
					} catch (e) {
						errorMessage = e;
					}
				} else {
					errorMessage = error;
				}
				errorMessage = errorMessage ? errorMessage : `Error executing the command ${command.trim()}`;
				const { message: formattedError, userFacing } = formatCommandErrorMessage(errorMessage, command);
				populateResultViewer(RESULT_INFO.LEVEL.ERROR, category, additionalInfo, formattedError);
				reject(new CommandExecutionError(formattedError, category, additionalInfo, { userFacing }));
				return;
			}
			resolve(hasJsonResponse ? JSON.parse(output) : output);
			if (!disableMetrics) {
				endWatch(additionalInfo, processes);
			}
		});

		childProcess.on('error', err => {
			const { message: formattedError, userFacing } = formatCommandErrorMessage(err.toString(), command);
			populateResultViewer(RESULT_INFO.LEVEL.ERROR, category, additionalInfo, formattedError);
			reject(new CommandExecutionError(formattedError, category, additionalInfo, { userFacing }));
			if (!disableMetrics) {
				endWatch(additionalInfo, processes);
			}
		});
	});
}

async function executeCommandinChunks(fileList, chunkSize, cmd, cmdInfo) {
	if (fileList.length > 0) {
		let fileIndex = 0;
		do {
			const endIndex = fileIndex + parseInt(chunkSize) > fileList.length ? fileList.length : fileIndex + parseInt(chunkSize);
			const fileChunk = fileList.slice(fileIndex, endIndex);
			await executeCommand(
				cmd.replace(/REPLACE_VALUE/g, fileChunk.map(file => `'${file}'`).join(' ')),
				cmdInfo?.category,
				cmdInfo?.additionalInfo,
				true
			);
			fileIndex = endIndex;
		} while (fileIndex < fileList.length);
	}
}

// =============================================================================
// API VERSION
// =============================================================================

async function getApiVersion(overriddenApiVersion, apiVersion) {
	const finalApiVersion = overriddenApiVersion || apiVersion;
	const regExpApiVersion = /\d\d\.0/;
	if (!regExpApiVersion.test(finalApiVersion)) {
		await executeCommand(getErrorCmdString(`Invalid API Version: ${finalApiVersion}`));
		process.exit(1);
	}
	return finalApiVersion;
}

// =============================================================================
// LOGGING / METRICS
// =============================================================================

function logWorkflowOverview() {
	logger('');
	logger('=== Branch-based Git auto-commit (Copado) ===');
	logger(
		`Compare ${baseBranchOrigin} → ${baseBranch}, apply changes on ${FEATURE_BRANCH || '[feature branch]'}, then merge into ${environmentBranch}.`
	);
	logger('');
	asyncCopadoLogMessage(`Auto-commit ${USER_STORY_NAME || 'user story'}`);
}

function logWorkflowStep(step, title, detail, updateCopadoStatus = false) {
	const header = `[Step ${step}/${WORKFLOW_STEP_COUNT}] ${title}`;
	logger(detail ? `${header}\n    ${detail}` : header);
	if (updateCopadoStatus) {
		asyncCopadoLogMessage(title);
	}
}

function logWorkflowStepDone(step, title) {
	logger(`[Step ${step}/${WORKFLOW_STEP_COUNT}] Completed: ${title}`);
}

function asyncCopadoLogMessage(msg, logLevel) {
	if (msg) {
		populateResultViewer(logLevel ? logLevel : RESULT_INFO.LEVEL.INFO, RESULT_INFO.CATEGORY.COPADO_INFO, '', msg);
		executeCommand(`copado -p "${msg.replace(/"/g, '\\"')}"`, RESULT_INFO.CATEGORY.COPADO_SERVICE);
	}
}

function populateResultViewer(level, category, additionalInfo, message) {
	if (message) {
		resultViewerJson.push({
			Level: level,
			Category: category,
			AdditionalInformation: additionalInfo,
			Message: message
		});
	}
}

const LOG_ICONS = Object.freeze({
	SECTION: '◆',
	STEP: '▸',
	OK: '✓',
	CMD: '→',
	WARN: '⚠',
	ERROR: '✗',
	INFO: 'ℹ',
	CONFIG: '⚙',
	GIT: '⎇',
	METRIC: '◉',
	DETAIL: '·'
});

function resolveLogIcon(line) {
	const trimmed = line.trim();
	if (!trimmed) {
		return null;
	}
	if (/^={5,}/.test(trimmed) || /OVERALL METRICS|EXECUTION SUMMARY|Branch-based Git auto-commit/.test(trimmed)) {
		return LOG_ICONS.SECTION;
	}
	if (/^\[Step \d+\/\d+\] Completed:/.test(trimmed)) {
		return LOG_ICONS.OK;
	}
	if (/^\[Step \d+\/\d+\]/.test(trimmed)) {
		return LOG_ICONS.STEP;
	}
	if (/^===>/.test(trimmed)) {
		return LOG_ICONS.CMD;
	}
	if (/WARN:/i.test(trimmed)) {
		return LOG_ICONS.WARN;
	}
	if (/^Error stack:/i.test(trimmed) || /^error:/i.test(trimmed)) {
		return LOG_ICONS.ERROR;
	}
	if (/^START /.test(trimmed)) {
		return LOG_ICONS.STEP;
	}
	if (/^END /.test(trimmed) || /Graceful early exit/i.test(trimmed)) {
		return LOG_ICONS.OK;
	}
	if (/Status Code: 2\d\d/.test(trimmed)) {
		return LOG_ICONS.OK;
	}
	if (/Status Code:/.test(trimmed)) {
		return LOG_ICONS.WARN;
	}
	if (/Total Time:/.test(trimmed) || /^\[[\w\s]+\] .+: [\d.N/A]/.test(trimmed)) {
		return LOG_ICONS.METRIC;
	}
	if (/^---/.test(trimmed) || /^resolved\./.test(trimmed) || /^ {4}/.test(line)) {
		return LOG_ICONS.DETAIL;
	}
	if (/^[a-zA-Z][\w]*:/.test(trimmed) && !/^git /i.test(trimmed)) {
		return LOG_ICONS.CONFIG;
	}
	if (
		/^[AMD?RCU]\s/.test(trimmed) ||
		/Merge-base|Deepening origin|Checking if the current|Staging \d|Changed files|Metadata files after|Change list written|Resolved \d|Commit \w+ not yet|already present|Nothing to commit|Waiting for remote ref/i.test(
			trimmed
		)
	) {
		return LOG_ICONS.GIT;
	}
	return LOG_ICONS.INFO;
}

function logger(text) {
	const message = text == null ? '' : String(text);
	for (const line of message.split('\n')) {
		const icon = resolveLogIcon(line);
		if (icon === null) {
			console.log(line);
		} else {
			console.log(`${icon}  ${line}`);
		}
	}
}

function startWatch(category, additionalInfo, processMap) {
	if (!additionalInfo || !category) return;
	const startTime = process.hrtime();
	if (!totalTimeByType[category]) totalTimeByType[category] = 0;
	processMap.set(additionalInfo, { name: additionalInfo, type: category, startTime, endTime: null, elapsedTime: null });
}

function endWatch(additionalInfo, processMap) {
	if (!additionalInfo) return;
	if (!processMap.has(additionalInfo)) {
		logger(`WARN: Process '${additionalInfo}' not started.`);
		return;
	}
	const processEntry = processMap.get(additionalInfo);
	const endTime = process.hrtime();
	const elapsedTime = process.hrtime(processEntry.startTime);
	processEntry.endTime = endTime;
	processEntry.elapsedTime = elapsedTime[0] * 1e9 + elapsedTime[1];
	processMap.set(additionalInfo, processEntry);
}

function printMetrics() {
	logger('\n');
	logger('====================      OVERALL METRICS      ====================');
	for (const proc of processes.values()) {
		const elapsed = proc.elapsedTime ? `${(proc.elapsedTime / 1e9).toFixed(2)} s` : 'N/A';
		logger(`  [${proc.type}] ${proc.name}: ${elapsed}`);
		if (proc.elapsedTime) {
			if (!totalTimeByType[proc.type]) totalTimeByType[proc.type] = 0;
			totalTimeByType[proc.type] += proc.elapsedTime;
		}
	}
	logger('====================       EXECUTION SUMMARY      ====================');
	Object.entries(totalTimeByType).forEach(([type, totalTime]) => {
		logger(`${type} Total Time: ${(totalTime / 1e9).toFixed(2)} seconds`);
	});
	logger('====================       EXECUTION SUMMARY      ====================\n');
}

// =============================================================================
// UTILITY
// =============================================================================

function getGitDepth(raw) {
	const n = parseInt(raw, 10);
	return isNaN(n) || n < 0 ? 100 : n;
}

function isTruthyFlag(value) {
	if (value === true) {
		return true;
	}
	if (value === false || value == null) {
		return false;
	}
	const normalized = String(value).trim().toLowerCase();
	return normalized === 'true' || normalized === '1' || normalized === 'yes';
}

function getCommitMessage() {
	const trimmed = commitMessage?.trim();
	if (trimmed) {
		return trimmed;
	}
	if (USER_STORY_NAME) {
		return `Auto-commit ${USER_STORY_NAME}: diff from ${baseBranchOrigin} to ${baseBranch}`;
	}
	return `Auto-commit: diff from ${baseBranchOrigin} to ${baseBranch}`;
}

function enrichResultDataWithArtifactContext(resultData) {
	if (USER_STORY_NAME) {
		resultData.userStoryName = USER_STORY_NAME;
	}
	if (USER_STORY_ID) {
		resultData.userStoryId = USER_STORY_ID;
	}
	return resultData;
}

function getPath(filePath) {
	return isTest ? path.join(__dirname, '__tests__', '__mockDir__', filePath) : filePath;
}

// =============================================================================
// INNER CLASS
// =============================================================================

class NoChangesEarlyExit extends Error {
	constructor(reason) {
		super(reason);
		this.name = 'NoChangesEarlyExit';
	}
}

class CommandExecutionError extends Error {
	constructor(message, category, additionalInfo, options = {}) {
		super(options.userFacing ? message : `${category ? category + ' - ' : ''}${additionalInfo ? additionalInfo + ' : ' : ''}${message}`);
		this.name = CUSTOM_ERROR.COMMAND_EXECUTION_ERROR;
		this.userFacing = !!options.userFacing;
	}
}

// =============================================================================
// EXPORTS
// =============================================================================

module.exports.execute = execute;
module.exports.validateInputs = validateInputs;
module.exports.initialSetup = initialSetup;
module.exports.createTargetDirectoryAndFetchBranch = createTargetDirectoryAndFetchBranch;
module.exports.fetchCreateFeatureBranch = fetchCreateFeatureBranch;
module.exports.resolveMergeBaseWithValidation = resolveMergeBaseWithValidation;
module.exports.validateWorkingBranchFromParent = validateWorkingBranchFromParent;
module.exports.getMergeBase = getMergeBase;
module.exports.computeMergeBase = computeMergeBase;
module.exports.validatesHistoricalFork = validatesHistoricalFork;
module.exports.isCommitReachable = isCommitReachable;
module.exports.fetchDeepenBranch = fetchDeepenBranch;
module.exports.getDiffFileList = getDiffFileList;
module.exports.parseDiffNameStatus = parseDiffNameStatus;
module.exports.resolveMetadataFromDiffFiles = resolveMetadataFromDiffFiles;
module.exports.restoreDeletedMetadataFiles = restoreDeletedMetadataFiles;
module.exports.parseEnrichedDiffChanges = parseEnrichedDiffChanges;
module.exports.toRepoRelativePath = toRepoRelativePath;
module.exports.enrichChangeList = enrichChangeList;
module.exports.varReplace = varReplace;
module.exports.findAndReplace = findAndReplace;
module.exports.processMetadata = processMetadata;
module.exports.commitAndUpdateEnvironmentBranches = commitAndUpdateEnvironmentBranches;
module.exports.hasRelevantGitChanges = hasRelevantGitChanges;
module.exports.hasCommitChangesFileEntries = hasCommitChangesFileEntries;
module.exports.getCurrentCommitId = getCurrentCommitId;
module.exports.getFilePathsFromStatus = getFilePathsFromStatus;
module.exports.gitCommitFiles = gitCommitFiles;
module.exports.gitPush = gitPush;
module.exports.configureGit = configureGit;
module.exports.fetchCheckoutBranch = fetchCheckoutBranch;
module.exports.changeWorkingDirectory = changeWorkingDirectory;
module.exports.executeAfterCommitOperations = executeAfterCommitOperations;
module.exports.mergeFeatureBranchInSource = mergeFeatureBranchInSource;
module.exports.checkSFDXProjectJson = checkSFDXProjectJson;
module.exports.hasConflict = hasConflict;
module.exports.finishCommit = finishCommit;
module.exports.updateResultWithCommitDetails = updateResultWithCommitDetails;
module.exports.copyVlocityFilesIfPresent = copyVlocityFilesIfPresent;
module.exports.reportNoChanges = reportNoChanges;
module.exports.NoChangesEarlyExit = NoChangesEarlyExit;
module.exports.getErrorCmdString = getErrorCmdString;
module.exports.uploadFile = uploadFile;
module.exports.uploadCopadoCommitChangesToUserStory = uploadCopadoCommitChangesToUserStory;
module.exports.mergeChangeLists = mergeChangeLists;
module.exports.fetchExistingCommitChanges = fetchExistingCommitChanges;
module.exports.deleteCommitChangesAttachments = deleteCommitChangesAttachments;
module.exports.copadoOrgGet = copadoOrgGet;
module.exports.copadoOrgDelete = copadoOrgDelete;
module.exports.uploadFileAtPath = uploadFileAtPath;
module.exports.uploadResultViewerJson = uploadResultViewerJson;
module.exports.downloadFile = downloadFile;
module.exports.executeCommand = executeCommand;
module.exports.executeCommandinChunks = executeCommandinChunks;
module.exports.getApiVersion = getApiVersion;
module.exports.asyncCopadoLogMessage = asyncCopadoLogMessage;
module.exports.populateResultViewer = populateResultViewer;
module.exports.logger = logger;
module.exports.startWatch = startWatch;
module.exports.endWatch = endWatch;
module.exports.printMetrics = printMetrics;
module.exports.getGitDepth = getGitDepth;
module.exports.getCommitMessage = getCommitMessage;
module.exports.getPath = getPath;

// =============================================================================
// EXECUTION
// =============================================================================

if (!isTest) {
	execute().catch(err => {
		console.error(err);
		process.exit(1);
	});
}