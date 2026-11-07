#!/usr/bin/env node
'use strict';

/**
 * Branch-based deploy.
 *
 *
 * @param baseBranch                                – branch that contains the changes to deploy (cloned & diffed)
 * @param baseBranchOrigin                          – branch to diff against (merge-base anchor)
 * @param destinationInstanceUrl                    – target (release) org instance URL
 * @param destinationSessionid                      – target org session id
 * @param destinationOrgId / destinationCredentialId / locale – data kit activation (gateway) context
 * @param destinationEnv                            – JSON array of env-var replacement pairs
 * @param findAndReplaceRules                       – Copado file id for the global find & replace rules
 * @param isValidation                              – 'true' for a dry-run validation, 'false' to deploy
 * @param testLevel / isProductionEnvironment – apex test config (RunSpecifiedTests runs @IsTest/@TestMethod classes from the diff; fails if production Apex/triggers are in the diff without tests; NoTestRun when the diff has no Apex)
 * @param gitDepth                                  – shallow clone / deepen depth
 * @param overriddenApiVersion / extraDeployFlags   – deploy command overrides
 */

const child_process = require('child_process'),
	crypto = require('crypto'),
	fs = require('fs'),
	path = require('path'),
	process = require('process'),
	{
		baseBranch,
		baseBranchOrigin,
		destinationSessionid,
		isValidation,
		destinationInstanceUrl,
		destinationOrgId,
		destinationCredentialId,
		locale,
		API_VERSION,
		isTest,
		gitDepth,
		destinationEnv,
		fetchDeployReportRetrialTimes,
		deployPollTime
	} = process.env,
	TEMP_DIRECTORY = getPath('/tmp'),
	APP_DIRECTORY = getPath('/app'),
	TARGET_DIRECTORY = `${APP_DIRECTORY}/repository`,
	ENCODED_CHANGES_FILE = 'encoded_changes.json',
	VAR_REPLACE_FILE_PATH = `${TEMP_DIRECTORY}/varReplace.json`,
	FILES_TO_DEPLOY = `${TEMP_DIRECTORY}/filesToIncludeInDeployment.json`,
	DIFF_CHANGE_FILE_PATH = `${TEMP_DIRECTORY}/diffChanges`,
	DIFF_CHANGE_ENRICHED_PATH = `${TEMP_DIRECTORY}/diffChanges.json`,
	DIFF_DELETE_CHANGE_FILE_PATH = `${TEMP_DIRECTORY}/diffDeletedChanges`,
	DIFF_DELETE_CHANGE_ENRICHED_PATH = `${TEMP_DIRECTORY}/diffDeletedChanges.json`,
	DELETED_METADATA_DIRECTORY = `${TEMP_DIRECTORY}/deletedMetadataRepository`,
	MAX_MERGE_BASE_FETCH_DEPTH = 2000,
	MAX_MERGE_BASE_DEEPEN_ATTEMPTS = 25,
	PORCELAIN_STATUS = { ADDED: 'A', DELETED: 'D', UNMERGED: 'U' },
	COPADO_INFO_PREFIX = 'CopadoFunction INFO',
	ACTIONS = {
		ADD: 'add',
		DELETE: 'delete'
	},
	TYPES = {
		DATA_PACKAGE_KIT_DEFINITION: 'datapackagekitdefinition'
	},
	TEST_LEVEL = {
		RUN_SPECIFIED_TESTS: 'RunSpecifiedTests',
		NO_TEST_RUN: 'NoTestRun',
		RUN_RELEVANT_TESTS: 'RunRelevantTests',
		RUN_LOCAL_TESTS: 'RunLocalTests',
		RUN_ALL_TESTS_IN_ORG: 'RunAllTestsInOrg'
	},
	// Copado global value set "Apex Test Level" (labels with spaces) → sf project deploy --test-level
	COPADO_TEST_LEVEL_TO_SF = {
		'No Test Run': TEST_LEVEL.NO_TEST_RUN,
		'Run Specified Tests': TEST_LEVEL.RUN_SPECIFIED_TESTS,
		'Run Relevant Tests': TEST_LEVEL.RUN_RELEVANT_TESTS,
		'Run Local Tests': TEST_LEVEL.RUN_LOCAL_TESTS,
		'Run All Tests In Org': TEST_LEVEL.RUN_ALL_TESTS_IN_ORG
	},
	CONSTANTS = {
		COMPONENT_TYPE: 'componentType',
		FULL_NAME: 'fullName',
		PROBLEM: 'problem'
	},
	DEPLOYMENT_STATUS = {
		CANCELING: 'Canceling',
		CANCELED: 'Canceled',
		PENDING: 'Pending',
		INPROGRESS: 'InProgress'
	},
	CATEGORY = { SFDX: 'sfdx', OTHER: 'other', VLOCITY: 'vlocity' },
	GIT_DEPTH = getGitDepth(gitDepth),
	COPADO_RETRIEVE_XML = 'CopadoDeploy.xml',
	COPADO_DESTRUCTIVE_XML = 'CopadoDestructive.xml',
	RESULT_INFO = {
		LEVEL: {
			INFO: 'INFO',
			ERROR: 'ERROR',
			WARN: 'WARN'
		},
		CATEGORY: {
			UNKNOWN_EXCEPTION: 'Unknown Exception',
			COPADO_INFO: 'Copado Info',
			APEX_TEST_RUN: 'Apex Test Run',
			FLOW_TEST_RUN: 'Flow Test Run',
			COPADO_METADATA_INTELLIGENCE: 'Copado Metadata Intelligence',
			GIT_SERVICE: 'Git Service',
			COPADO_SERVICE: 'Copado Service',
			SFDX_CLI: 'SFDX CLI',
			METADATA_EXECUTION: `Metadata ${isValidation === 'true' ? 'Validation' : 'Deployment'}`,
			FILE_SYSTEM: 'File System'
		},
		ADDITIONAL_INFORMATION: {
			APEX_TEST_FAILURE: 'Apex Test Failure',
			CODE_COVERAGE_ERROR: 'Code Coverage Error',
			FLOW_TEST_FAILURE: 'Flow Test Failure',
			APEX_TEST_RUN_SUMMARY: 'Test Run Summary',
			CONSOLIDATED_RESULT: `Consolidated ${isValidation === 'true' ? 'Validation' : 'Deployment'} Result`,
			METADATA_DEPLOYMENT_REQUEST: 'Metadata Deployment Request',
			POLL_STATUS: `Poll ${isValidation === 'true' ? 'Validation' : 'Deployment'} Status`,
			GIT_STATUS: 'Git Status',
			GIT_COMMIT: 'Git Commit',
			GIT_CONFIG: 'Git Configuration',
			GIT_CLONE: 'Git Clone',
			GIT_DIFF: 'Git Diff',
			MERGE_BASE: 'Git Merge Base',
			BASE_BRANCH_CHECKOUT: 'Base Branch Checkout',
			SFDX_CONFIG: 'SFDX Configuration',
			SFDX_DEPLOYMENT: 'SFDX Deployment',
			ENRICHER_SERVICE: 'Enricher Service',
			METADATA_PROCESSOR: 'Metadata Processor',
			METADATA_ANALYZER: 'Metadata Analyzer',
			ENV_VARIABLE_REPLACEMENT: 'Environment Variable Replacement',
			GLOBAL_FIND_AND_REPLACE: 'Global Find and Replace',
			UPLOAD_FILES: 'Upload Files',
			DATA_KIT_ACTIVATION: 'Data Kit Activation',
			DATA_KIT_STATUS: 'Data Kit Deployment Status',
			GIT_PUSH: 'Git Push',
			GIT_ADD: 'Git Add',
			TEST_CLASSES_EXECUTED: 'Test classes executed'
		}
	},
	resultViewerJson = [],
	CUSTOM_ERROR = {
		COMMAND_EXECUTION_ERROR: 'CommandExecutionError'
	},
	RESULT_TABLE_COLUMNS = [
		{
			label: 'Level',
			fieldName: 'Level',
			type: 'text',
			wrapText: true,
			customLabel: 'Level',
			initialWidth: 80
		},
		{
			label: 'Category',
			fieldName: 'Category',
			type: 'text',
			wrapText: true,
			customLabel: 'Category',
			initialWidth: 120
		},
		{
			label: 'Additional Information',
			fieldName: 'AdditionalInformation',
			type: 'text',
			wrapText: true,
			customLabel: 'Additional_Information',
			initialWidth: 200
		},
		{
			label: 'Message',
			fieldName: 'Message',
			type: 'text',
			wrapText: true,
			customLabel: 'Message'
		}
	],
	RESULT_TABLE_HEADER = {
		label: 'Deployment Result',
		customLabel: 'Deployment_Result'
	},
	PROBLEM_TYPE = {
		WARNING: 'warning',
		ERROR: 'error'
	},
	HEADER_ICON = 'standard:note',
	NUMBER_OF_REPORT_RETRIALS = parseInt(fetchDeployReportRetrialTimes) >= 0 ? parseInt(fetchDeployReportRetrialTimes) : 10,
	DEPLOY_REPORT_POLL_TIME = parseInt(deployPollTime) >= 0 ? parseInt(deployPollTime) : 1,
	DATA_KIT_POLL_INITIAL_INTERVAL_MS = 1000,
	DATA_KIT_POLL_MAX_INTERVAL_MS = 30000,
	DATA_KIT_POLL_BACKOFF_MULTIPLIER = 2,
	DATA_KIT_POLL_MAX_TIMEOUT_MS = 10 * 60 * 1000;

let sourceApiVersion = isTest ? API_VERSION : '';
let isSfMetadataPresent,
	executionError,
	totalTimeByType = {},
	processes = [],
	hasPrefetchedVolume,
	changedApexClassFiles = [],
	changedApexTriggerFiles = [];

// EXECUTION

function logInputParameters() {
	const INPUT_PARAMETER_NAMES = [
		'baseBranch',
		'baseBranchOrigin',
		'destinationInstanceUrl',
		'destinationSessionid',
		'destinationOrgId',
		'destinationCredentialId',
		'destinationEnv',
		'git_json',
		'findAndReplaceRules',
		'isValidation',
		'gitName',
		'gitEmail',
		'testLevel',
		'gitDepth',
		'overriddenApiVersion',
		'isProductionEnvironment',
		'fetchDeployReportRetrialTimes',
		'deployPollTime',
		'repositoryId',
		'extraDeployFlags',
		'locale',
		'timeout',
		'API_VERSION',
		'CF_RESULTID',
		'CF_SF_ENDPOINT'
	];

	logger('========== Input parameters ==========');
	for (const name of INPUT_PARAMETER_NAMES) {
		logger(`${name}: ${process.env[name] ?? ''}`);
	}
	logger('--- resolved for execution ---');
	logger(`resolved.gitDepth: ${GIT_DEPTH}`);
	logger('======================================');
}

async function execute() {
	const { overriddenApiVersion, gitEmail, gitName, findAndReplaceRules } = process.env;
	logInputParameters();
	hasPrefetchedVolume = fs.existsSync(TARGET_DIRECTORY);
	this.logger(`hasPrefetchedVolume: ${hasPrefetchedVolume}`);
	try {
		sourceApiVersion = this.getApiVersion(overriddenApiVersion, API_VERSION);

		// Clone the release branch and configure git before diffing so rename detection is disabled.
		await this.fetchBaseBranch(baseBranch, GIT_DEPTH);
		await this.configureGit(gitEmail, gitName);

		// Derive the deploy change list from the diff between the merge-base (where the release
		// branch forked off baseBranchOrigin) and the base branch tip, writing encoded_changes.json.
		await this.buildChangeListFromDiff(baseBranchOrigin, baseBranch, GIT_DEPTH);

		this.checkChangesWrtCategory(`${APP_DIRECTORY}/${ENCODED_CHANGES_FILE}`);

		const changes = this.prepareChanges(`${APP_DIRECTORY}/${ENCODED_CHANGES_FILE}`);
		this.validateSFDXProjectJson(`${TARGET_DIRECTORY}/sfdx-project.json`);
		await this.updateSourceApiVersion(`${TARGET_DIRECTORY}/sfdx-project.json`, sourceApiVersion);
		if (changes.add?.length) {
			const callEnricherForReplaceServices = this.hasVarreplaceEnabled(destinationEnv) || findAndReplaceRules;
			if (callEnricherForReplaceServices) {
				await this.enrichChangeList(`${APP_DIRECTORY}/${ENCODED_CHANGES_FILE}`);
				this.getFilesToIncludeInDeployment(`${APP_DIRECTORY}/${ENCODED_CHANGES_FILE}`);
			}
			await this.processMetadata(changes, `${APP_DIRECTORY}/${ENCODED_CHANGES_FILE}`, !callEnricherForReplaceServices);
			await this.varReplace(destinationEnv, FILES_TO_DEPLOY);
			await this.yamlFindAndReplace(findAndReplaceRules, baseBranch, FILES_TO_DEPLOY);
		}
		if (isSfMetadataPresent) {
			await this.setInstanceUrl(destinationInstanceUrl);
			const manifest = this.createManifest(changes);
			await this.deploy(manifest, isValidation);
			if (isValidation === 'false') {
				await this.activateDataKitsIfPresent(changes);
			}
		}
	} catch (err) {
		this.logger(`Error stack: ${err.stack}`);
		if (!(err instanceof CommandExecutionError)) {
			this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, RESULT_INFO.CATEGORY.UNKNOWN_EXCEPTION, 'See logs for more info', err.message);
		}
		executionError = err.message || err?.toString() || 'Unknown Error occurred';
	} finally {
		if (resultViewerJson?.length) {
			await this.uploadResultViewerJson(resultViewerJson, RESULT_TABLE_COLUMNS, RESULT_TABLE_HEADER, HEADER_ICON);
		}
		if (executionError) {
			await this.executeCommand(this.getErrorCmdString(executionError));
		}
		this.printMetrics();
		if (executionError) {
			process.exit(1);
		}
	}
}

async function asyncCopadoLogMessage(msg, logLevel) {
	if (msg) {
		this.populateResultViewer(logLevel ? logLevel : RESULT_INFO.LEVEL.INFO, RESULT_INFO.CATEGORY.COPADO_INFO, '', msg);
		await this.executeCommand(`copado -p "${msg}"`);
	}
}

/**
 * Builds the deploy change list from a git diff between the point where the release branch
 * forked off baseBranchOrigin (the merge-base) and the base branch tip. The diff paths are
 * resolved to Salesforce metadata name/type via the enricher (--changefile) so the resulting
 * [{ n, t, a, c }] list matches the encoded_changes.json contract the deploy flow consumes.
 * Added/modified files become `add`; files deleted on the release branch become `delete`
 * (later deployed as destructive changes). The repository must already be cloned/checked out
 * on the release branch and git configured before calling this.
 */
async function buildChangeListFromDiff(baseBranchOrigin, baseBranch, gitDepth) {
	this.logger('START Building deploy change list from git diff');
	this.asyncCopadoLogMessage(`Comparing ${baseBranchOrigin} → ${baseBranch}`);

	// Fetch baseBranchOrigin (merge-base anchor only – no checkout). Allow failure: a deepen pass follows.
	await this.executeCommand(
		`copado-git-get -g "git fetch origin ${baseBranchOrigin} --depth ${gitDepth}" || true`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE
	);

	const divergenceSha = await this.resolveMergeBaseWithValidation(baseBranchOrigin, baseBranch, gitDepth);
	const diffChanges = this.getDiffFileList(divergenceSha, baseBranch);
	this.logger(`Changed files (${diffChanges.all.length}): ${diffChanges.all.join(', ')}`);

	changedApexClassFiles = diffChanges.addOrModify.filter(f => f.toLowerCase().endsWith('.cls'));
	changedApexTriggerFiles = diffChanges.addOrModify.filter(f => f.toLowerCase().endsWith('.trigger'));

	const { changeList } = await this.resolveMetadataFromDiffFiles(diffChanges, divergenceSha);
	fs.writeFileSync(`${APP_DIRECTORY}/${ENCODED_CHANGES_FILE}`, JSON.stringify(changeList, null, 2));
	this.logger(`Deploy change list written (${changeList.length} entries)`);
	this.logger('END Building deploy change list from git diff');
	return changeList;
}

async function resolveMergeBaseWithValidation(parent, working, initialDepth) {
	this.asyncCopadoLogMessage(`Finding where ${working} diverged from ${parent}`);
	const deepenStep = initialDepth;
	let parentDeepenTotal = 0;
	let workingDeepenTotal = 0;

	for (let attempt = 0; attempt < MAX_MERGE_BASE_DEEPEN_ATTEMPTS; attempt++) {
		const mergeBaseSha = this.computeMergeBase(parent, working);

		if (mergeBaseSha && this.isCommitReachable(mergeBaseSha) && this.validatesHistoricalFork(parent, working, mergeBaseSha)) {
			this.logger(`Merge-base commit: ${mergeBaseSha} (found on attempt ${attempt + 1})`);
			return mergeBaseSha;
		}

		if (parentDeepenTotal < MAX_MERGE_BASE_FETCH_DEPTH) {
			this.logger(`Deepening origin/${parent} by ${deepenStep} (total parent deepen: ${parentDeepenTotal + deepenStep})`);
			await this.fetchDeepenBranch(parent, deepenStep);
			parentDeepenTotal += deepenStep;
			continue;
		}

		if (workingDeepenTotal < MAX_MERGE_BASE_FETCH_DEPTH) {
			this.logger(`Deepening origin/${working} by ${deepenStep} (total working deepen: ${workingDeepenTotal + deepenStep})`);
			await this.fetchDeepenBranch(working, deepenStep);
			workingDeepenTotal += deepenStep;
			continue;
		}

		break;
	}

	throw new Error(
		`Could not resolve merge-base between '${parent}' and '${working}' within shallow depth ` +
			`(max ${MAX_MERGE_BASE_FETCH_DEPTH} per branch). Increase gitDepth or verify branch relationship.`
	);
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
		child_process.execFileSync('git', ['cat-file', '-e', `${sha}^{commit}`], { cwd: TARGET_DIRECTORY, stdio: 'pipe' });
		return true;
	} catch {
		return false;
	}
}

function validatesHistoricalFork(parent, working, mergeBaseSha) {
	return this.isAncestorCommit(mergeBaseSha, `origin/${parent}`) && this.isAncestorCommit(mergeBaseSha, `origin/${working}`);
}

function isAncestorCommit(ancestorSha, descendantRef) {
	try {
		child_process.execFileSync('git', ['merge-base', '--is-ancestor', ancestorSha, descendantRef], { cwd: TARGET_DIRECTORY, stdio: 'pipe' });
		return true;
	} catch {
		return false;
	}
}

async function fetchDeepenBranch(branch, deepenBy) {
	await this.executeCommand(
		`copado-git-get -g "git fetch origin ${branch} --deepen=${deepenBy}" || true`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE
	);
}

function getDiffFileList(divergenceSha, working) {
	const rawDiff = child_process
		.execFileSync('git', ['diff', '--name-status', '--diff-filter=ACMRTD', `${divergenceSha}...origin/${working}`], {
			cwd: TARGET_DIRECTORY,
			encoding: 'utf8'
		})
		.toString();
	return this.parseDiffNameStatus(rawDiff);
}

function parseDiffNameStatus(rawDiff) {
	const addOrModify = new Set();
	const added = new Set();
	const deleteFiles = new Set();

	rawDiff
		.split('\n')
		.map(line => line.trim())
		.filter(line => line.length > 0)
		.forEach(line => {
			const parts = line.split(/\t+/);
			const status = parts[0];

			if (status === PORCELAIN_STATUS.ADDED) {
				added.add(parts[parts.length - 1]);
				addOrModify.add(parts[parts.length - 1]);
			} else if (status === PORCELAIN_STATUS.DELETED) {
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
		added: [...added],
		delete: [...deleteFiles],
		all: [...new Set([...addOrModify, ...deleteFiles])]
	};
}

async function resolveMetadataFromDiffFiles(diffChanges, divergenceSha) {
	this.asyncCopadoLogMessage('Identifying changed metadata components');

	const existingFiles = diffChanges.addOrModify.filter(filePath => fs.existsSync(path.join(TARGET_DIRECTORY, filePath)));
	const deletedFiles = this.restoreDeletedMetadataFiles(diffChanges.delete, divergenceSha);

	if (!existingFiles.length && !deletedFiles.length) {
		this.logger('No metadata files to resolve in the workspace');
		return { changeList: [], metadataFiles: [] };
	}

	let addChanges = { changeList: [], metadataFiles: [] };
	if (existingFiles.length) {
		fs.writeFileSync(DIFF_CHANGE_FILE_PATH, existingFiles.join('\n'));
		await this.enrichDiffFilePaths(TARGET_DIRECTORY, DIFF_CHANGE_FILE_PATH, DIFF_CHANGE_ENRICHED_PATH);
		addChanges = this.parseEnrichedDiffChanges(DIFF_CHANGE_ENRICHED_PATH, ACTIONS.ADD, TARGET_DIRECTORY);
	}

	let deleteChanges = { changeList: [], metadataFiles: [] };
	if (deletedFiles.length) {
		fs.writeFileSync(DIFF_DELETE_CHANGE_FILE_PATH, deletedFiles.join('\n'));
		await this.enrichDiffFilePaths(DELETED_METADATA_DIRECTORY, DIFF_DELETE_CHANGE_FILE_PATH, DIFF_DELETE_CHANGE_ENRICHED_PATH);
		deleteChanges = this.parseEnrichedDiffChanges(DIFF_DELETE_CHANGE_ENRICHED_PATH, ACTIONS.DELETE, DELETED_METADATA_DIRECTORY);
	}

	const changeList = this.dedupeChanges([...addChanges.changeList, ...deleteChanges.changeList]);
	this.logger(`Resolved ${changeList.length} unique metadata component(s) for deployment`);
	return { changeList, metadataFiles: addChanges.metadataFiles };
}

async function enrichDiffFilePaths(repoPath, changeFilePath, outputPath) {
	const cmd = `enricher --repo '${repoPath}/' --changefile '${changeFilePath}' --out '${outputPath}' --operation COMMIT '--handleLabels'`;
	await this.executeCommand(cmd, RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE, RESULT_INFO.ADDITIONAL_INFORMATION.ENRICHER_SERVICE);
}

function restoreDeletedMetadataFiles(deletedFiles, divergenceSha) {
	if (!deletedFiles.length) {
		return [];
	}

	fs.rmSync(DELETED_METADATA_DIRECTORY, { recursive: true, force: true });
	fs.mkdirSync(DELETED_METADATA_DIRECTORY, { recursive: true });
	if (!this.restoreFileFromGit(divergenceSha, 'sfdx-project.json', DELETED_METADATA_DIRECTORY, true)) {
		this.copyCurrentProjectConfig(DELETED_METADATA_DIRECTORY);
	}

	const restoredFiles = [];
	for (const filePath of deletedFiles) {
		if (this.restoreFileFromGit(divergenceSha, filePath, DELETED_METADATA_DIRECTORY, false)) {
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
			this.logger(`WARN: Could not restore deleted path ${filePath} from ${ref}: ${error.message}`);
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
			changeList.push({ n: item.n, t: item.t, a: action, c: CATEGORY.SFDX });
		}

		for (const filePath of this.extractFilePathsFromEnrichedItem(item)) {
			const relativePath = this.toRepoRelativePath(filePath, repoRoot);
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
			this.logger(`WARN: Could not parse enricher file paths for ${item.n}: ${error.message}`);
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

function checkChangesWrtCategory(sfdxFilePath) {
	let areOthersPresent = false;
	if (fs.existsSync(sfdxFilePath)) {
		const commitChanges = this.readFromPath(sfdxFilePath);
		isSfMetadataPresent = commitChanges?.some(change => change.c?.toLowerCase() === CATEGORY.SFDX);
		areOthersPresent = commitChanges?.some(change => change.c?.toLowerCase() === CATEGORY.OTHER);
	}

	const logs = [];

	logs.push(isSfMetadataPresent ? 'Salesforce changes found.' : 'Salesforce changes not found.');
	logs.push(areOthersPresent ? 'Other changes found.' : 'Other changes not found.');

	this.logger(logs.join('\n'));

	if (!isSfMetadataPresent) {
		this.logger('No deployable Salesforce metadata changes found in the diff.');
	}
}

function prepareChanges(filePath) {
	let changes = {};
	changes.all = this.readFromPath(filePath);
	changes = {
		...changes,
		add: changes.all.filter(selectedMetadata => selectedMetadata.a.toLowerCase() == ACTIONS.ADD),
		delete: changes.all.filter(selectedMetadata => selectedMetadata.a.toLowerCase() == ACTIONS.DELETE),
		getSFMetadataList(type) {
			return this[type].reduce((metadatas, metadata) => {
				if (metadata.c?.toLowerCase() === CATEGORY.SFDX) {
					return getMetadataTypeAndName(metadatas, metadata);
				} else {
					return metadatas;
				}
			}, '');
		}
	};
	return changes;
}

async function fetchBaseBranch(baseBranch, gitDepth) {
	this.logger('START Fetching release branch');
	fs.mkdirSync(TARGET_DIRECTORY, { recursive: true });
	process.chdir(TARGET_DIRECTORY);
	this.asyncCopadoLogMessage(`Fetching ${baseBranch}`);
	await this.executeCommand(
		`
        copado-git-get "${baseBranch}" --depth "${gitDepth}" || exit 1
		${hasPrefetchedVolume ? 'copado-git-get -g "git pull origin ' + baseBranch + ' --depth ' + gitDepth + '"' : ''}`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.BASE_BRANCH_CHECKOUT
	);
	this.logger('END Fetching release branch');
}

async function configureGit(gitEmail, gitName) {
	const configureGit = `
    git config --local user.email "${gitEmail}" || exit 1
    git config --local user.name "${gitName}" || exit 1
    git config --global diff.renames false || exit 1
    git config --global merge.renames false || exit 1
    git config --global status.renames false || exit 1
    git config --global core.quotePath false || exit 1
    `;
	await this.executeCommand(`${configureGit}`, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CONFIG);
}

function validateSFDXProjectJson(sfdxProjectJsonPath) {
	if (!fs.existsSync(sfdxProjectJsonPath)) {
		throw new Error(
			'Invalid configuration. sfdx-project.json is invalid or missing at project root. Copado Commit and Deploy operations are required to run from within a valid sfdx project.'
		);
	}
}

async function updateSourceApiVersion(sfdxProjectJsonPath, sourceApiVersion) {
	let fileContent = this.readFromPath(sfdxProjectJsonPath);
	if (fileContent.sourceApiVersion !== sourceApiVersion) {
		const commitMessage = `Updated sourceApiVersion from ${fileContent.sourceApiVersion} to ${sourceApiVersion} in sfdx-project.json to align the commit, promote and deploy operations with the latest supported api version of Copado`;
		fileContent.sourceApiVersion = sourceApiVersion;
		fs.writeFileSync(sfdxProjectJsonPath, JSON.stringify(fileContent, null, 2));
		await this.commitGit(commitMessage);
	}
}

async function enrichChangeList(changeListPath) {
	this.asyncCopadoLogMessage('Identifying Metadata Filepaths');
	await this.executeCommand(
		`
enricher -p ${changeListPath} --repo ${TARGET_DIRECTORY}/ --quick true --enrichmentMethod v3 || exit 1`, //Enrichment method v3 -> V3 optimizes by grouping by metadata type, using folder-specific paths with validation, and processing mapped types before unmapped types, which should improve performance and accuracy for large change sets.
		RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE,
		RESULT_INFO.ADDITIONAL_INFORMATION.ENRICHER_SERVICE
	);
}

async function processMetadata(changes, changeListPath, enrich) {
	if (isSfMetadataPresent) {
		this.asyncCopadoLogMessage('START Metadata processor');
		this.logger('START Metadata processor');
		// Call Metadata processor with --enrich if we have not identified the files to deploy
		await this.executeCommand(
			`metadata-processor "${changeListPath}" "${TARGET_DIRECTORY}" -o TRIM ${enrich ? '--enrich' : ''} || exit 1`,
			RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE,
			RESULT_INFO.ADDITIONAL_INFORMATION.METADATA_PROCESSOR
		);

		const parentMetadataFile = this.getParentMetadataFile(changeListPath);
		if (fs.existsSync(parentMetadataFile)) {
			this.addParentMetadataToOriginalChangeList(changes, this.readFromPath(parentMetadataFile));
		}
		this.logger('END Metadata processor');
		this.asyncCopadoLogMessage('END Metadata processor');
	}
}

function addParentMetadataToOriginalChangeList(changes, parentMetadataList) {
	if (parentMetadataList?.length) {
		changes.add = changes.add.concat(parentMetadataList.filter(change => change.a.toLowerCase() == ACTIONS.ADD));
	}
}

function getParentMetadataFile(filePath) {
	const index = filePath.lastIndexOf('/');
	const directory = filePath.substring(0, index + 1);

	return directory + 'internal_' + filePath.substring(index + 1);
}

function varReplace(environmentVariables, filesToInclude, valueToName, repositoryPath) {
	if (!this.hasVarreplaceEnabled(environmentVariables)) {
		return Promise.resolve();
	}
	this.asyncCopadoLogMessage('Replacing environment variables');
	fs.writeFileSync(VAR_REPLACE_FILE_PATH, environmentVariables);
	const repoPathParam = repositoryPath ? repositoryPath : TARGET_DIRECTORY; // To apply on temporary directory for custom labels
	const valueToNameParam = valueToName ? '--valuename=true' : '';
	const filesToIncludeParam = filesToInclude ? '--include=' + filesToInclude : '';

	const command = `varreplace '${VAR_REPLACE_FILE_PATH}' '${repoPathParam}' ${valueToNameParam} ${filesToIncludeParam}`;
	return this.executeCommand(
		command,
		RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE,
		RESULT_INFO.ADDITIONAL_INFORMATION.ENV_VARIABLE_REPLACEMENT
	);
}

function yamlFindAndReplace(findAndReplaceRules, branch, filesToInclude, repositoryPath) {
	if (!findAndReplaceRules) {
		return Promise.resolve();
	}
	const yamlDir = 'Copado';
	const additionalInfo = RESULT_INFO.ADDITIONAL_INFORMATION.GLOBAL_FIND_AND_REPLACE;
	this.asyncCopadoLogMessage(`Applying ${yamlDir} find and replace rules`);
	const repoPathToPass = repositoryPath ? repositoryPath : TARGET_DIRECTORY; // To apply on temporary directory for custom labels
	return this.executeCommand(
		`
	copado --downloadfiles "${findAndReplaceRules}" --downloaddir ${TEMP_DIRECTORY}/ || exit 1
	
	yamlreplace "${TEMP_DIRECTORY}/${yamlDir}" "${repoPathToPass}" -b "${branch}" ${filesToInclude ? ' --include=' + `${filesToInclude}` : ''} || exit 1
`,
		RESULT_INFO.CATEGORY.COPADO_METADATA_INTELLIGENCE,
		additionalInfo
	);
}

// Create SFDX Deploy command w.r.t. to flags
async function getSFDXDeployCmd(isDestructiveChangesPresent, isValidation) {
	const { testLevel, isProductionEnvironment, extraDeployFlags } = process.env;
	let sfdxDeployCommand = 'sf project deploy start --ignore-conflicts --json --async';

	if (isValidation == 'true') {
		sfdxDeployCommand += ' --dry-run';
	}
	if (extraDeployFlags) {
		sfdxDeployCommand += ` ${extraDeployFlags}`;
	}

	sfdxDeployCommand += await this.getTestRunParam(testLevel, isProductionEnvironment);

	sfdxDeployCommand +=
		` --manifest ${COPADO_RETRIEVE_XML}` +
		(isDestructiveChangesPresent ? ` --post-destructive-changes ${COPADO_DESTRUCTIVE_XML} --ignore-warnings` : '');
	return `${sfdxDeployCommand}`;
}

/**
 * Maps Copado Environment picklist values (Apex Test Level global value set, with spaces)
 * to Salesforce CLI deploy --test-level values (PascalCase, no spaces).
 * Pass-through if already in SF format.
 */
function normalizeTestLevel(testLevel) {
	if (!testLevel) {
		return '';
	}
	const trimmed = String(testLevel).trim();
	if (COPADO_TEST_LEVEL_TO_SF[trimmed]) {
		return COPADO_TEST_LEVEL_TO_SF[trimmed];
	}
	const compact = trimmed.split(/\s+/).join('');
	const sfValues = new Set(Object.values(COPADO_TEST_LEVEL_TO_SF));
	if (sfValues.has(compact)) {
		return compact;
	}
	return compact;
}

async function getTestRunParam(testLevel, isProductionEnvironment) {
	let testRunParam = '';
	if (testLevel) {
		let testRun = normalizeTestLevel(testLevel);
		if (testRun !== testLevel?.trim()) {
			this.logger(`Normalized testLevel "${testLevel}" → "${testRun}" for sf deploy`);
		}
		if (testRun === TEST_LEVEL.RUN_SPECIFIED_TESTS) {
			const apexTestClasses = this.getTestClassesFromChangedFiles();
			if (apexTestClasses.length) {
				if (!(testRun === TEST_LEVEL.NO_TEST_RUN && isProductionEnvironment === 'true')) {
					testRunParam += ` --test-level ${testRun}`;
					testRunParam += ` --tests ${apexTestClasses.join(' ')}`;
					return testRunParam;
				}
			} else if (this.hasProductionApexInChangedFiles()) {
				const errorMsg = 'RunSpecifiedTests was requested but list of changes contains Apex classes or triggers without test classes.';
				await this.asyncCopadoLogMessage(errorMsg, RESULT_INFO.LEVEL.ERROR);
				throw new Error(errorMsg);
			} else {
				const warningMsg =
					'RunSpecifiedTests was requested but no Apex classes or triggers were found in the list of changes. Using NoTestRun as fallback test level.';
				await this.asyncCopadoLogMessage(warningMsg, RESULT_INFO.LEVEL.WARN);
				testRun = TEST_LEVEL.NO_TEST_RUN;
			}
		}
		if (testRun && !(testRun === TEST_LEVEL.NO_TEST_RUN && isProductionEnvironment === 'true')) {
			testRunParam += ` --test-level ${testRun}`;
		}
	}
	return testRunParam;
}

const APEX_TEST_ANNOTATION_REGEX = /@\s*(isTest|testMethod)\b/i;

function readChangedApexFileContent(relativePath) {
	const absPath = path.join(TARGET_DIRECTORY, relativePath);
	if (!fs.existsSync(absPath)) {
		return '';
	}
	return fs.readFileSync(absPath, 'utf8');
}

function apexClassFileHasTestAnnotation(relativePath) {
	return APEX_TEST_ANNOTATION_REGEX.test(readChangedApexFileContent(relativePath));
}

/**
 * True when the diff includes non-test Apex (.cls without @IsTest/@TestMethod) or any .trigger file.
 */
function hasProductionApexInChangedFiles() {
	for (const relativePath of changedApexClassFiles) {
		if (readChangedApexFileContent(relativePath) && !apexClassFileHasTestAnnotation(relativePath)) {
			return true;
		}
	}
	for (const relativePath of changedApexTriggerFiles) {
		if (fs.existsSync(path.join(TARGET_DIRECTORY, relativePath))) {
			return true;
		}
	}
	return false;
}

/**
 * Scans added/modified Apex class files (.cls) from the git diff and returns the names of those
 * that contain an @IsTest or @TestMethod annotation, to be passed to the deploy command as --tests
 * when testLevel is RunSpecifiedTests.
 *
 * @returns {string[]} Unique Apex test class names (file basename without the .cls extension).
 */
function getTestClassesFromChangedFiles() {
	const testClasses = new Set();
	for (const relativePath of changedApexClassFiles) {
		if (apexClassFileHasTestAnnotation(relativePath)) {
			testClasses.add(path.basename(relativePath, '.cls'));
		}
	}
	return [...testClasses];
}

async function uploadDeploymentResultOnJobStep(isValidation) {
	const deployResultDir = this.getDeploymentResultFile(isValidation);
	if (fs.existsSync(deployResultDir)) {
		const uploadFile = `copado --uploadfile ${deployResultDir}`;
		await this.executeCommand(
			uploadFile,
			RESULT_INFO.CATEGORY.COPADO_SERVICE,
			RESULT_INFO.ADDITIONAL_INFORMATION.UPLOAD_FILES,
			false,
			false,
			false
		);
	} else {
		this.logger(`Could not find ${deployResultDir} `);
	}
}

async function createDeploymentResultFile(deployResult, isValidation) {
	const deployResultDir = this.getDeploymentResultFile(isValidation);

	fs.writeFileSync(deployResultDir, JSON.stringify(deployResult, null, 2));
	await this.uploadDeploymentResultOnJobStep(isValidation);
}

function getDeploymentResultFile(isValidation) {
	return `${TEMP_DIRECTORY}/${isValidation === 'true' ? 'Validation' : 'Deployment'}Result.json`;
}

/**
 * Writes test execution counts into the Result Viewer (same message as legacy success-path row).
 *
 * @param {object} deployResult - Full deploy-report JSON from the CLI.
 */
function printApexTestExecutionSummary(deployResult) {
	const result = deployResult?.result;
	if (!result) return;
	const message = `Total Tests : ${result.numberTestsTotal} | Completed Tests : ${result.numberTestsCompleted} | Failed Tests : ${result.numberTestErrors}`;
	this.populateResultViewer(
		RESULT_INFO.LEVEL.INFO,
		RESULT_INFO.CATEGORY.APEX_TEST_RUN,
		RESULT_INFO.ADDITIONAL_INFORMATION.APEX_TEST_RUN_SUMMARY,
		message
	);
}

async function handleDeployResult(deployResult, isValidation) {
	await this.createDeploymentResultFile(deployResult, isValidation);

	let errorResponse = '';
	const testLevelNormalized = normalizeTestLevel(process.env.testLevel);
	const isRunRelevantTests = testLevelNormalized === TEST_LEVEL.RUN_RELEVANT_TESTS;
	const details = deployResult?.result?.details,
		componentFailures = details?.componentFailures,
		componentSuccesses = details?.componentSuccesses,
		failures = details?.runTestResult?.failures,
		codeCoverageWarnings = details?.runTestResult?.codeCoverageWarnings,
		flowCoverageWarnings = details?.runTestResult?.flowCoverageWarnings;

	// If any errors or warning, display to progress indicator and fail the job execution
	if (deployResult?.status && deployResult?.message) {
		errorResponse = `${deployResult?.message}`;
		this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, RESULT_INFO.CATEGORY.METADATA_EXECUTION, '', errorResponse);
	}

	if (deployResult?.result?.status == DEPLOYMENT_STATUS.CANCELED) {
		errorResponse = `The ${isValidation === 'true' ? 'validation' : 'deployment'} was cancelled on the target org.`;
		this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, RESULT_INFO.CATEGORY.METADATA_EXECUTION, '', errorResponse);
	}
	if (deployResult?.result?.errorMessage) {
		errorResponse = `${deployResult?.result?.errorMessage}`;
		this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, RESULT_INFO.CATEGORY.METADATA_EXECUTION, '', errorResponse);
	}

	// apex test failures
	if (failures) {
		if (isRunRelevantTests) {
			this.printApexTestExecutionSummary(deployResult);
			this.printExecutedTestClasses(details?.runTestResult);
		}
		const failureMessage = this.getFailedTestsErrorMessage(failures);
		this.populateResultViewer(
			RESULT_INFO.LEVEL.ERROR,
			RESULT_INFO.CATEGORY.APEX_TEST_RUN,
			RESULT_INFO.ADDITIONAL_INFORMATION.APEX_TEST_FAILURE,
			failureMessage
		);
		errorResponse = this.populateErrorResponse(failureMessage, errorResponse);
	}

	// code coverage errors
	if (codeCoverageWarnings) {
		const failureMessage = this.getFailedTestsErrorMessage(codeCoverageWarnings);
		this.populateResultViewer(
			RESULT_INFO.LEVEL.ERROR,
			RESULT_INFO.CATEGORY.APEX_TEST_RUN,
			RESULT_INFO.ADDITIONAL_INFORMATION.CODE_COVERAGE_ERROR,
			failureMessage
		);
		errorResponse = this.populateErrorResponse(failureMessage, errorResponse);
	}

	// flow coverage errors
	if (flowCoverageWarnings) {
		const failureMessage = this.getFailedTestsErrorMessage(flowCoverageWarnings);
		this.populateResultViewer(
			RESULT_INFO.LEVEL.ERROR,
			RESULT_INFO.CATEGORY.FLOW_TEST_RUN,
			RESULT_INFO.ADDITIONAL_INFORMATION.FLOW_TEST_FAILURE,
			failureMessage
		);
		errorResponse = this.populateErrorResponse(failureMessage, errorResponse);
	}

	// metadata component deployment failures
	if (componentFailures) {
		const errorMetadata = this.filterFailedMedataByProblemType(componentFailures, [PROBLEM_TYPE.ERROR, PROBLEM_TYPE.WARNING]);
		if (errorMetadata.length) {
			const failureMessage = this.getFailedComponentsErrorMessage(errorMetadata);
			this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, RESULT_INFO.CATEGORY.METADATA_EXECUTION, '', failureMessage);
			errorResponse = this.populateErrorResponse(failureMessage, errorResponse);
		}
	}

	// deployment warnings
	if (componentSuccesses?.length) {
		const warningMetadata = this.filterFailedMedataByProblemType(componentSuccesses, [PROBLEM_TYPE.WARNING]);
		if (warningMetadata?.length) {
			const message = `WARNING Deploying Metadata: ${this.getFailedComponentsErrorMessage(warningMetadata)}`;
			this.asyncCopadoLogMessage(message.substring(0, 254), RESULT_INFO.LEVEL.WARN);
			this.logger(message);
		}
	}

	if (errorResponse) {
		throw new CommandExecutionError(errorResponse.substring(0, 131072), RESULT_INFO.CATEGORY.METADATA_EXECUTION, '');
	}

	if (!deployResult.status) {
		this.printApexTestExecutionSummary(deployResult);
		const message = componentSuccesses?.reduce((metadataInfo, component) => {
			return component.componentType
				? metadataInfo
					? `${metadataInfo}, ${component.componentType} : ${component.fullName}`
					: `${component.componentType} : ${component.fullName}`
				: metadataInfo;
		}, '');
		this.populateResultViewer(
			RESULT_INFO.LEVEL.INFO,
			RESULT_INFO.CATEGORY.METADATA_EXECUTION,
			RESULT_INFO.ADDITIONAL_INFORMATION.CONSOLIDATED_RESULT,
			message
		);
	}

	if (isRunRelevantTests) {
		this.printExecutedTestClasses(details?.runTestResult);
	}
}

/**
 * Collects unique test class names from both successes and
 * failures in the runTestResult block and logs them to the result viewer
 * and the console. Called when testLevel === "Run Relevant Tests" after a
 * successful deployment, and before throwing when deployment fails due to errors.
 *
 * @param {object} runTestResult - deployResult.result.details.runTestResult
 */
function printExecutedTestClasses(runTestResult) {
	if (!runTestResult) {
		this.logger('No test run result available to extract test class names.');
		return;
	}

	const classNames = new Set();

	// Collect from successful test methods
	const successes = runTestResult.successes;
	if (Array.isArray(successes)) {
		successes.forEach(t => {
			if (t.name) classNames.add(t.name);
		});
	} else if (successes?.name) {
		classNames.add(successes.name);
	}

	// Collect from failed test methods
	const failures = runTestResult.failures;
	if (Array.isArray(failures)) {
		failures.forEach(t => {
			if (t.name) classNames.add(t.name);
		});
	} else if (failures?.name) {
		classNames.add(failures.name);
	}

	if (!classNames.size) {
		this.logger('Run Relevant Tests: no test class names found in the deployment report.');
		return;
	}

	const message = `${[...classNames].sort().join(', ')}`;

	this.logger(message);
	this.populateResultViewer(
		RESULT_INFO.LEVEL.INFO,
		RESULT_INFO.CATEGORY.APEX_TEST_RUN,
		RESULT_INFO.ADDITIONAL_INFORMATION.TEST_CLASSES_EXECUTED,
		message
	);
}

function filterFailedMedataByProblemType(failedComponents, problemType) {
	let result = [];
	if (Array.isArray(failedComponents)) {
		result = failedComponents.filter(component => problemType?.includes(component.problemType?.toLowerCase()));
	} else if (problemType?.includes(failedComponents.problemType?.toLowerCase())) {
		result = [failedComponents];
	}
	return result;
}

function getFailedComponentsErrorMessage(failedComponents) {
	let result = '';
	if (Array.isArray(failedComponents)) {
		result = failedComponents
			.map(failure => failure[CONSTANTS.COMPONENT_TYPE].concat(':', failure[CONSTANTS.FULL_NAME], ':', failure[CONSTANTS.PROBLEM]))
			.join('\n');
	} else {
		result = failedComponents[CONSTANTS.COMPONENT_TYPE]
			.concat(':', failedComponents[CONSTANTS.FULL_NAME], ':', failedComponents[CONSTANTS.PROBLEM])
			.toString();
	}
	return result;
}

function getFailedTestsErrorMessage(failedTests) {
	let result = '';
	if (Array.isArray(failedTests)) {
		let failedTestsError = failedTests.map(failedTest => {
			let error = '';
			error = failedTest.name ? (error ? error.concat('-', failedTest.name) : error.concat(failedTest.name)) : error;
			error = failedTest.methodName ? (error ? error.concat('-', failedTest.methodName) : error.concat(failedTest.methodName)) : error;
			error = error ? error.concat('-', failedTest.message) : error.concat(failedTest.message);
			return error;
		});
		if (failedTestsError?.length) {
			result = failedTestsError.join('\n');
		}
	} else {
		if (typeof failedTests.name != 'object') {
			result = result.concat(`${failedTests.name}`);
		}
		result = failedTests.methodName ? (result ? result.concat('-', failedTests.methodName) : result.concat(failedTests.methodName)) : result;
		result = result ? result.concat('-', failedTests.message) : result.concat(failedTests.message);
	}
	return result;
}

function populateErrorResponse(errorMessage, errorResponse) {
	const delimiter = '\n';
	errorResponse = (errorResponse && errorResponse?.trim().concat(`${delimiter}`, errorMessage.trim())) || errorResponse.concat(errorMessage.trim());
	return errorResponse;
}

async function commitGit(commitMessage) {
	await this.executeCommand(
		`
    git add . || exit 1 # add all the resolved changes, if any
    git commit -am "${commitMessage}" || true`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_COMMIT
	);
}

async function setInstanceUrl(instanceUrl) {
	const baseUrl = this.getInstanceUrl(instanceUrl);
	await this.executeCommand(
		`
# Set instance URL within sfdx-config.json
SF_ACCESS_TOKEN=${destinationSessionid} sf org login access-token --instance-url ${baseUrl} --set-default --no-prompt || exit 1
sf org disable tracking`,
		RESULT_INFO.CATEGORY.SFDX_CLI,
		RESULT_INFO.ADDITIONAL_INFORMATION.SFDX_CONFIG
	);
}

async function activateDataKitsIfPresent(changes) {
	const dataKitChanges = (changes?.all || []).filter(change => change.t?.toLowerCase() === TYPES.DATA_PACKAGE_KIT_DEFINITION);
	if (!dataKitChanges.length) {
		this.logger('No DataPackageKitDefinition found in changes. Skipping data kit activation.');
		return;
	}
	const missing = [];
	if (!destinationOrgId) missing.push('destinationOrgId');
	if (!destinationCredentialId) missing.push('destinationCredentialId');
	if (!process.env.CF_SF_ENDPOINT) missing.push('CF_SF_ENDPOINT');
	if (missing.length) {
		throw new Error(`Cannot activate ${dataKitChanges.length} Data Kit(s): missing required context (${missing.join(', ')}).`);
	}
	this.logger(`Found ${dataKitChanges.length} Data Kit(s) to activate`);
	await this.asyncCopadoLogMessage('Activating Data Kits');
	const { results, flowInterviewGuids } = await this.activateDataKits(dataKitChanges);
	this.logger(`Data Kit activation result: ${JSON.stringify(results)}`);
	if (flowInterviewGuids.length) {
		await this.queryDataKitDeploymentStatus(flowInterviewGuids);
	}
}

async function activateDataKits(dataKitChanges) {
	const requestId = crypto.randomUUID();
	const dataKitSelected = dataKitChanges.map(change => ({ name: change.n, type: change.t }));
	this.logger(`Generated Event ID: ${requestId}`);
	const gatewayRequest = {
		path: '/release/promotion/activatedatakits',
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			'x-event-id': requestId,
			'x-locale': locale || 'en',
			'platform-experience': 'sfdx',
			'x-copado-api-url': process.env.CF_SF_ENDPOINT
		},
		body: {
			dataKitSelected,
			targetOrgId: destinationOrgId,
			targetCredentialId: destinationCredentialId
		}
	};

	const safeJsonStr = JSON.stringify(gatewayRequest).replace(/'/g, `'\\''`);
	const command = `copado --gateway '${safeJsonStr}'`;

	this.logger('Calling Copado CLI Gateway to activate Data Kits...');
	const output = await this.executeCommand(command, RESULT_INFO.CATEGORY.COPADO_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.DATA_KIT_ACTIVATION);

	let response;
	try {
		response = JSON.parse(output);
	} catch (e) {
		throw new Error(`Data kit activation returned an unparseable response: ${String(output).substring(0, 500)}`);
	}

	const responseData = Array.isArray(response) ? response : response?.data;
	if (!Array.isArray(responseData)) {
		throw new Error(`Data kit activation response did not contain a results array: ${JSON.stringify(response).substring(0, 500)}`);
	}

	const FAILED_STATUSES = new Set(['failed', 'error']);
	const results = {};
	const flowInterviewGuids = [];
	const failed = [];
	for (const item of responseData) {
		const dataKitName = item?.dataKitName;
		const guid = item?.flowInterviewGuid;
		if (!dataKitName) {
			continue;
		}
		const status = item?.status ? String(item.status) : 'UNKNOWN';
		results[dataKitName] = status;
		if (FAILED_STATUSES.has(status.toLowerCase())) {
			failed.push(`${dataKitName}: ${status}`);
		}
		if (guid) {
			flowInterviewGuids.push({ dataKitName, guid });
		}
	}

	if (failed.length) {
		throw new Error(`Data kit activation failed for: ${failed.join('; ')}`);
	}
	return { results, flowInterviewGuids, response };
}

async function queryDataKitDeploymentStatus(flowInterviewGuids) {
	this.logger('--- Polling Data Kit Deployment Status ---');

	const guidValues = flowInterviewGuids.map(({ guid }) => `'${guid}'`).join(',');
	const guidMap = new Map(flowInterviewGuids.map(({ dataKitName, guid }) => [guid, dataKitName]));
	const soql = `SELECT Id, ComponentName, DataKitName, DataSpaceName, DeployJob, DeploymentError, DeploymentStatus, FlowInterviewIdentifier FROM DataKitDeploymentLog WHERE FlowInterviewIdentifier IN (${guidValues})`;
	const TERMINAL_STATUSES = new Set(['Successful', 'Failed', 'Error']);
	const FAILED_STATUSES = new Set(['Failed', 'Error']);

	let interval = DATA_KIT_POLL_INITIAL_INTERVAL_MS;
	const startTime = Date.now();

	for (;;) {
		const elapsed = Date.now() - startTime;
		if (elapsed >= DATA_KIT_POLL_MAX_TIMEOUT_MS) {
			throw new Error(
				`Data kit deployment did not complete within ${DATA_KIT_POLL_MAX_TIMEOUT_MS / 1000}s. Some components may still be deploying.`
			);
		}

		this.logger(
			`Polling data kit deployment status (elapsed: ${Math.round(elapsed / 1000)}s, next interval: ${Math.round(interval / 1000)}s)...`
		);

		// Query inside try/catch so transient query failures retry; evaluate results outside so a
		// terminal deployment failure throws (instead of being swallowed by the retry handler).
		let records;
		try {
			const output = await this.executeCommand(
				`sf data query --query "${soql}" --json`,
				RESULT_INFO.CATEGORY.SFDX_CLI,
				RESULT_INFO.ADDITIONAL_INFORMATION.DATA_KIT_STATUS,
				false,
				true
			);
			records = JSON.parse(output)?.result?.records || [];
		} catch (err) {
			this.logger(`WARN: Failed to query data kit deployment status: ${err.message}. Retrying...`);
			await sleep(interval);
			interval = Math.min(interval * DATA_KIT_POLL_BACKOFF_MULTIPLIER, DATA_KIT_POLL_MAX_INTERVAL_MS);
			continue;
		}

		if (!records.length) {
			this.logger('No data kit deployment log records found yet. Retrying...');
			await sleep(interval);
			interval = Math.min(interval * DATA_KIT_POLL_BACKOFF_MULTIPLIER, DATA_KIT_POLL_MAX_INTERVAL_MS);
			continue;
		}

		const hasInProgress = records.some(r => !r.DeploymentStatus || !TERMINAL_STATUSES.has(r.DeploymentStatus));
		for (const record of records) {
			const kitName = record.DataKitName || guidMap.get(record.FlowInterviewIdentifier) || 'Unknown';
			const componentName = record.ComponentName || record.DeployJob || 'Unknown';
			const status = record.DeploymentStatus || 'Unknown';
			const error = record.DeploymentError ? ` | Error: ${record.DeploymentError}` : '';
			this.logger(`  [${kitName}] ${componentName}: ${status}${error}`);
		}

		if (!hasInProgress) {
			const failed = records.filter(r => FAILED_STATUSES.has(r.DeploymentStatus));
			if (failed.length) {
				const detail = failed
					.map(r => {
						const kitName = r.DataKitName || guidMap.get(r.FlowInterviewIdentifier) || 'Unknown';
						const componentName = r.ComponentName || r.DeployJob || 'Unknown';
						return `[${kitName}] ${componentName}: ${r.DeploymentStatus}${r.DeploymentError ? ` - ${r.DeploymentError}` : ''}`;
					})
					.join('; ');
				throw new CommandExecutionError(
					`Data kit deployment failed: ${detail}`,
					RESULT_INFO.CATEGORY.METADATA_EXECUTION,
					RESULT_INFO.ADDITIONAL_INFORMATION.DATA_KIT_STATUS
				);
			}
			this.logger('All data kit components deployed successfully.');
			return;
		}

		this.logger('Some data kit components still in progress. Waiting...');
		await sleep(interval);
		interval = Math.min(interval * DATA_KIT_POLL_BACKOFF_MULTIPLIER, DATA_KIT_POLL_MAX_INTERVAL_MS);
	}
}

function sleep(ms) {
	return new Promise(resolve => setTimeout(resolve, ms));
}

function getErrorCmdString(error) {
	const suffix = 'Please check the logs for details.';
	const errorMessage = JSON.stringify(error.trim()?.substring(0, 32760) + '; ' + suffix);
	return `copado -p "Error" -e ${errorMessage}`;
}

function readFromPath(filePath) {
	if (!fs.existsSync(filePath)) {
		throw new Error(`Could not find file at path: ${filePath}`);
	}
	const data = fs.readFileSync(filePath, 'utf-8');
	let result;
	try {
		result = JSON.parse(data);
	} catch (err) {
		throw new Error(`Content at ${filePath} is not a valid JSON`);
	}
	return result;
}

function getApiVersion(overriddenApiVersion, apiVersion) {
	const finalApiVersion = overriddenApiVersion || apiVersion;
	const regExpApiVersion = /\d\d\.0/;
	if (!regExpApiVersion.test(finalApiVersion)) {
		throw new Error(`Invalid API Version: ${finalApiVersion}`);
	}
	return finalApiVersion;
}

function getPath(filePath) {
	return isTest ? `${__dirname}/__tests__/__mockDir__${filePath}` : filePath;
}

function getMetadataTypeAndName(metadatas, metadata) {
	return metadatas ? `${metadatas},${metadata.t}:${metadata.n}` : `${metadata.t}:${metadata.n}`;
}

function createManifest(changes) {
	let ADD_MANIFEST = changes.getSFMetadataList('add');
	const DELETE_MANIFEST = changes.getSFMetadataList('delete');
	let result = { isSuccess: false, isDestructiveChangesPresent: false };

	if (DELETE_MANIFEST && ADD_MANIFEST) {
		const deleteSet = new Set(DELETE_MANIFEST.split(','));
		ADD_MANIFEST = ADD_MANIFEST.split(',')
			.filter(item => !deleteSet.has(item))
			.join(',');
	}

	this.buildManifest(ADD_MANIFEST, false);
	result.isSuccess = true;

	if (DELETE_MANIFEST) {
		this.buildManifest(DELETE_MANIFEST, true);
		result.isSuccess = true;
		result.isDestructiveChangesPresent = true;
	}

	return result;
}

function buildManifest(changesList, isDestructiveManifest, manifestFileName) {
	let manifestFileNameConsidered = `${TARGET_DIRECTORY}/${COPADO_RETRIEVE_XML}`;
	if (isDestructiveManifest) {
		manifestFileNameConsidered = `${TARGET_DIRECTORY}/${COPADO_DESTRUCTIVE_XML}`;
	} else if (manifestFileName) {
		manifestFileNameConsidered = manifestFileName;
	}
	// Create Map
	let metadataByType = new Map();
	changesList.split(',').forEach(element => {
		const metadataItem = element.split(':');
		if (!metadataByType.has(metadataItem[0])) {
			metadataByType.set(metadataItem[0], []);
		}
		metadataByType.get(metadataItem[0]).push(metadataItem[1]);
	});

	// Create manifest file
	let manifest = [];
	manifest.push('<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>\n');
	manifest.push('<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n');
	metadataByType.forEach((value, key) => {
		if (value && key) {
			manifest.push('\t<types>\n');
			value.forEach(item => {
				manifest.push(`\t\t<members>${item}</members>\n`);
			});

			manifest.push(`\t\t<name>${key}</name>\n`);
			manifest.push('\t</types>\n');
		}
	});

	manifest.push(`\t<version>${sourceApiVersion}</version>\n`);
	manifest.push('</Package>\n');
	fs.writeFileSync(manifestFileNameConsidered, manifest.join(''));
}

async function deploy(manifest, isValidation) {
	this.logger('START -Salesforce- Deployment');
	let deployResult;
	if (manifest.isSuccess) {
		this.asyncCopadoLogMessage('START -Salesforce- Deploying Changes');
		const deployCommand = await this.getSFDXDeployCmd(manifest.isDestructiveChangesPresent, isValidation);
		const deploymentRequest = await this.executeCommand(
			deployCommand,
			RESULT_INFO.CATEGORY.METADATA_EXECUTION,
			RESULT_INFO.ADDITIONAL_INFORMATION.METADATA_DEPLOYMENT_REQUEST,
			true,
			true,
			false
		);
		if (deploymentRequest?.status) {
			throw new Error(`${deploymentRequest.commandName} : ${deploymentRequest.message}`);
		} else {
			this.logger(`Deployment Request Id:  ${deploymentRequest?.result?.id}`);
			deployResult = await this.checkDeploymentStatus(deploymentRequest?.result?.id, 0);
			await this.handleDeployResult(deployResult, isValidation);
		}
		this.asyncCopadoLogMessage('END -Salesforce- Deploying Changes');
	}
	this.logger('END -Salesforce- Deployment');
	return deployResult;
}

async function checkDeploymentStatus(jobId, numberOfRetries) {
	this.startWatch(RESULT_INFO.CATEGORY.METADATA_EXECUTION, RESULT_INFO.ADDITIONAL_INFORMATION.POLL_STATUS, processes);
	let response = await this.executeCommand(
		`sf project deploy report --wait ${DEPLOY_REPORT_POLL_TIME} --job-id ${jobId} --json || true`,
		RESULT_INFO.CATEGORY.METADATA_EXECUTION,
		RESULT_INFO.ADDITIONAL_INFORMATION.POLL_STATUS,
		true,
		true,
		true
	);
	this.endWatch(RESULT_INFO.ADDITIONAL_INFORMATION.POLL_STATUS, processes);
	if (response?.status && (response?.message?.includes('ETIMEDOUT') || response?.message?.includes('Metadata API request failed'))) {
		if (numberOfRetries < NUMBER_OF_REPORT_RETRIALS) {
			this.logger(`Fetching Deployment Report failed : ${response?.message}
        Retrying Attempt ${++numberOfRetries}`);
			return await this.checkDeploymentStatus(jobId, ++numberOfRetries);
		} else {
			return response;
		}
	}
	if (
		response?.result?.status == DEPLOYMENT_STATUS.CANCELING ||
		response?.result?.status == DEPLOYMENT_STATUS.INPROGRESS ||
		response?.result?.status == DEPLOYMENT_STATUS.PENDING
	) {
		numberOfRetries = 0;
		return await this.checkDeploymentStatus(jobId, numberOfRetries);
	} else {
		return response;
	}
}

function getGitDepth(gitDepth) {
	gitDepth = parseInt(gitDepth);
	return gitDepth >= 0 ? gitDepth : 100;
}

function logger(text) {
	console.log(text);
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

function uploadResultViewerJson(data, columns, header, headerIcon) {
	const RESULT_VIEWER_JSON_PATH = `${TEMP_DIRECTORY}/ResultViewer.json`;

	const fileContent = { data, columns, header, headerIcon };
	fs.writeFileSync(RESULT_VIEWER_JSON_PATH, JSON.stringify(fileContent, null, 2));
	return this.uploadFileAtPath(RESULT_VIEWER_JSON_PATH);
}

function uploadFileAtPath(filePath, parentId) {
	const command = `copado --uploadfile "${filePath}" ${parentId ? '--parentid ' + parentId : ''}`;
	return this.executeCommand(command, RESULT_INFO.CATEGORY.COPADO_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.UPLOAD_FILES);
}

function executeCommand(command, category, additionalInfo, hasJsonResponse, disableLog, disableMetrics, errorToBeShown, options) {
	this.logger(`===> ${command}`);
	return new Promise((resolve, reject) => {
		let output = '',
			error = '';

		if (!disableMetrics) {
			this.startWatch(category, additionalInfo, processes);
		}
		const childProcess = child_process.spawn(command, [], options ? options : { shell: true });

		childProcess.stdout.on('data', data => {
			const outputStream = data?.toString();
			if (!disableLog) {
				this.logger(outputStream);
			}
			output += outputStream;
		});

		childProcess.stderr.on('data', data => {
			const errorStream = data?.toString();
			this.logger(errorStream);
			error += errorStream;
		});

		childProcess.on('close', code => {
			if (code !== 0) {
				this.logger(`Code: ${code}`);
				let errorMessage = '';
				if (hasJsonResponse) {
					try {
						resolve(JSON.parse(output));
					} catch (error) {
						errorMessage = error;
					}
				} else {
					errorMessage = errorToBeShown ? (error ? `${errorToBeShown} : ${error}` : errorToBeShown) : error;
				}
				errorMessage = errorMessage ? errorMessage : `Error executing the command ${command.trim()}`;

				this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, category, additionalInfo, errorMessage);
				const truncatedError = JSON.stringify(
					errorMessage
						.split('\n')
						.filter(msg => !msg.includes(COPADO_INFO_PREFIX))
						.join(' ')
				);
				if (!disableMetrics) {
					this.endWatch(additionalInfo, processes);
				}
				reject(new CommandExecutionError(truncatedError, category, additionalInfo));
				return;
			}
			if (!disableMetrics) {
				this.endWatch(additionalInfo, processes);
			}
			resolve(hasJsonResponse ? JSON.parse(output) : output);
		});

		childProcess.on('error', error => {
			this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, category, additionalInfo, error);
			const truncatedError = JSON.stringify(
				error
					.split('\n')
					.filter(msg => !msg.includes(COPADO_INFO_PREFIX))
					.join(' ')
			);
			if (!disableMetrics) {
				this.endWatch(additionalInfo, processes);
			}
			reject(new CommandExecutionError(truncatedError, category, additionalInfo));
		});
		if (!disableMetrics) {
			this.endWatch(additionalInfo, processes);
		}
	});
}

function startWatch(processType, processName, processes) {
	if (!processName || !processType) {
		return;
	}
	const startTime = process.hrtime();
	if (!totalTimeByType[processType]) {
		totalTimeByType[processType] = 0;
	}
	processes.push({
		name: processName,
		type: processType,
		startTime,
		endTime: null,
		elapsedTime: null
	});
}

function endWatch(processType, processes) {
	if (!processType) {
		return;
	}
	const processIndex = processes.length;
	if (!processIndex && processes[processIndex - 1].type !== processType) {
		console.error(`Process '${processType}' not started.`);
		return;
	}
	const endTime = process.hrtime();
	const elapsedTime = process.hrtime(processes[processIndex - 1].startTime);
	processes[processIndex - 1].endTime = endTime;
	processes[processIndex - 1].elapsedTime = elapsedTime[0] * 1e9 + elapsedTime[1];
}

function printMetrics() {
	this.logger('\n');
	this.logger('   ====================      OVERALL METRICS      ====================   ');
	processes.forEach(process => {
		const startTime = process.startTime ? this.formatTime(process.startTime) : 'N/A';
		const endTime = process.endTime ? this.formatTime(process.endTime) : 'N/A';
		const elapseTime = process.elapsedTime ? `${(process.elapsedTime / 1e9).toFixed(2)} s` : 'N/A';
		this.logger(`| ${process.type} | ${process.name} | ${startTime} | ${endTime} | ${elapseTime} |`);
		if (process.elapsedTime) {
			if (!totalTimeByType[process.type]) {
				totalTimeByType[process.type] = 0;
			}
			totalTimeByType[process.type] += process.elapsedTime;
		}
	});
	this.logger('\n' + '   ====================       EXECUTION SUMMARY      ====================   ');
	// Print total aggregate time by type
	Object.entries(totalTimeByType).forEach(([type, totalTime]) => {
		this.logger(`${type} Total Time: ${(totalTime / 1e9).toFixed(2)} seconds`);
	});
	this.logger('   ====================       EXECUTION SUMMARY      ====================   ' + '\n');
}

function formatTime(time) {
	const date = new Date(time[0] * 1000 + time[1] / 1e6);
	const hours = date.getUTCHours().toString().padStart(2, '0');
	const minutes = date.getUTCMinutes().toString().padStart(2, '0');
	const seconds = date.getUTCSeconds().toString().padStart(2, '0');
	const milliseconds = date.getUTCMilliseconds().toString().padStart(3, '0');
	return `${hours}:${minutes}:${seconds}.${milliseconds}`;
}

function getInstanceUrl(instanceUrl) {
	return instanceUrl?.substring(0, instanceUrl?.indexOf('/', instanceUrl?.indexOf('/') + 2));
}

class CommandExecutionError extends Error {
	constructor(message, category, additionalInfo) {
		super(`${category ? category + ' - ' : ''}${additionalInfo ? additionalInfo + ' : ' : ''}${message}`);
		this.name = CUSTOM_ERROR.COMMAND_EXECUTION_ERROR;
	}
}

function getFilesToIncludeInDeployment(changesFilePath) {
	const filesToInclude = this.getFilePathsFromChanges(changesFilePath, [ACTIONS.ADD]);
	fs.writeFileSync(FILES_TO_DEPLOY, JSON.stringify(filesToInclude));
}

function getFilePathsFromChanges(changeFilePath, actions, categories) {
	let changeList = this.readFromPath(changeFilePath);
	let filePaths = new Set();
	if (actions?.length || categories?.length) {
		changeList = changeList.filter(change => {
			let isValid = true;
			if (actions?.length) {
				isValid = isValid && actions.includes(change.a?.toLowerCase());
			}
			if (categories?.length) {
				isValid = isValid && categories?.includes(change.c?.toLowerCase());
			}
			return isValid && change.j && change.j !== '';
		});
	}

	for (let i = 0; i < changeList.length; i++) {
		const change = changeList[i];
		const jsonAdditionalInfo = JSON.parse(change.j);
		let filesToBeAdded = jsonAdditionalInfo?.filePath?.filter(file => fs.existsSync(file) && fs.statSync(file).isFile());
		const deletedFiles = jsonAdditionalInfo?.deleteFilesFromGit;
		if (deletedFiles?.length) {
			this.logger(`Deleted files to be staged : ${deletedFiles}`);
			filesToBeAdded.push(...deletedFiles);
		}

		if (change.c.toLowerCase() !== CATEGORY.VLOCITY && change.a.toLowerCase() === ACTIONS.DELETE) {
			filesToBeAdded = [
				...jsonAdditionalInfo.deleteMapping.cascadeLocators,
				...jsonAdditionalInfo.deleteMapping.nestedComponents.reduce((result, cmp) => {
					result.push(...cmp.cascadeLocators);
					return result;
				}, [])
			];
		}
		if (filesToBeAdded) {
			filePaths = new Set([...filePaths, ...filesToBeAdded]);
		}
	}

	return [...filePaths];
}

function hasVarreplaceEnabled(environmentVariables) {
	if (environmentVariables && JSON.parse(environmentVariables)?.length) {
		return true;
	}
	return false;
}

module.exports.buildChangeListFromDiff = buildChangeListFromDiff;
module.exports.resolveMergeBaseWithValidation = resolveMergeBaseWithValidation;
module.exports.computeMergeBase = computeMergeBase;
module.exports.isCommitReachable = isCommitReachable;
module.exports.validatesHistoricalFork = validatesHistoricalFork;
module.exports.isAncestorCommit = isAncestorCommit;
module.exports.fetchDeepenBranch = fetchDeepenBranch;
module.exports.getDiffFileList = getDiffFileList;
module.exports.parseDiffNameStatus = parseDiffNameStatus;
module.exports.resolveMetadataFromDiffFiles = resolveMetadataFromDiffFiles;
module.exports.enrichDiffFilePaths = enrichDiffFilePaths;
module.exports.restoreDeletedMetadataFiles = restoreDeletedMetadataFiles;
module.exports.copyCurrentProjectConfig = copyCurrentProjectConfig;
module.exports.restoreFileFromGit = restoreFileFromGit;
module.exports.parseEnrichedDiffChanges = parseEnrichedDiffChanges;
module.exports.dedupeChanges = dedupeChanges;
module.exports.extractFilePathsFromEnrichedItem = extractFilePathsFromEnrichedItem;
module.exports.toRepoRelativePath = toRepoRelativePath;
module.exports.prepareChanges = prepareChanges;
module.exports.fetchBaseBranch = fetchBaseBranch;
module.exports.configureGit = configureGit;
module.exports.updateSourceApiVersion = updateSourceApiVersion;
module.exports.validateSFDXProjectJson = validateSFDXProjectJson;
module.exports.enrichChangeList = enrichChangeList;
module.exports.processMetadata = processMetadata;
module.exports.getParentMetadataFile = getParentMetadataFile;
module.exports.addParentMetadataToOriginalChangeList = addParentMetadataToOriginalChangeList;
module.exports.varReplace = varReplace;
module.exports.yamlFindAndReplace = yamlFindAndReplace;
module.exports.getSFDXDeployCmd = getSFDXDeployCmd;
module.exports.getTestRunParam = getTestRunParam;
module.exports.normalizeTestLevel = normalizeTestLevel;
module.exports.getTestClassesFromChangedFiles = getTestClassesFromChangedFiles;
module.exports.hasProductionApexInChangedFiles = hasProductionApexInChangedFiles;
module.exports.uploadDeploymentResultOnJobStep = uploadDeploymentResultOnJobStep;
module.exports.handleDeployResult = handleDeployResult;
module.exports.filterFailedMedataByProblemType = filterFailedMedataByProblemType;
module.exports.getFailedTestsErrorMessage = getFailedTestsErrorMessage;
module.exports.getFailedComponentsErrorMessage = getFailedComponentsErrorMessage;
module.exports.populateErrorResponse = populateErrorResponse;
module.exports.commitGit = commitGit;
module.exports.setInstanceUrl = setInstanceUrl;
module.exports.activateDataKitsIfPresent = activateDataKitsIfPresent;
module.exports.activateDataKits = activateDataKits;
module.exports.queryDataKitDeploymentStatus = queryDataKitDeploymentStatus;
module.exports.sleep = sleep;
module.exports.getErrorCmdString = getErrorCmdString;
module.exports.readFromPath = readFromPath;
module.exports.getApiVersion = getApiVersion;
module.exports.execute = execute;
module.exports.createManifest = createManifest;
module.exports.buildManifest = buildManifest;
module.exports.deploy = deploy;
module.exports.getGitDepth = getGitDepth;
module.exports.createDeploymentResultFile = createDeploymentResultFile;
module.exports.getDeploymentResultFile = getDeploymentResultFile;
module.exports.checkChangesWrtCategory = checkChangesWrtCategory;
module.exports.logger = logger;
module.exports.asyncCopadoLogMessage = asyncCopadoLogMessage;
module.exports.populateResultViewer = populateResultViewer;
module.exports.uploadFileAtPath = uploadFileAtPath;
module.exports.uploadResultViewerJson = uploadResultViewerJson;
module.exports.checkDeploymentStatus = checkDeploymentStatus;
module.exports.executeCommand = executeCommand;
module.exports.startWatch = startWatch;
module.exports.endWatch = endWatch;
module.exports.formatTime = formatTime;
module.exports.printMetrics = printMetrics;
module.exports.getInstanceUrl = getInstanceUrl;
module.exports.getFilePathsFromChanges = getFilePathsFromChanges;
module.exports.getFilesToIncludeInDeployment = getFilesToIncludeInDeployment;
module.exports.hasVarreplaceEnabled = hasVarreplaceEnabled;

module.exports.printExecutedTestClasses = printExecutedTestClasses;
module.exports.printApexTestExecutionSummary = printApexTestExecutionSummary;

// EXECUTION

!isTest && this.execute();