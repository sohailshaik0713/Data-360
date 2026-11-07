/*
This file is generated and isn't the actual source code for this
managed global class.
This read-only file shows the class's global constructors,
methods, variables, and properties.
To enable code to compile, all methods return null.
*/
global class PitForwardPromotionModels {
    global PitForwardPromotionModels() {

    }
global class DiscoveryResult {
    global Set<Id> candidateUserStoryIds;
    global Map<Id,Datetime> commitJobEndTimeByUserStoryId;
    global Map<Id,Id> commitJobIdByUserStoryId;
    global Map<Id,Datetime> commitTimeByUserStoryId;
    global String errorCode;
    global String errorMessage;
    global Set<Id> intermediateCandidateIds;
    global Id nextEnvironmentId;
    global Boolean pitAvailable;
    global List<copado.PitForwardPromotionModels.PromotedIntoSourceMeta> promotedIntoSource;
    global Id sourceEnvironmentId;
    global Set<Id> storiesWithCommitInSourceEnv;
    global Set<Id> storiesWithCommitOutsideSourceEnv;
    global Set<Id> userStoriesWithDeploymentTasks;
    global DiscoveryResult() {

    }
}
global class PromotedIntoSourceMeta {
    global Datetime commitTime;
    global Datetime deployEndTime;
    global Id deployJobExecutionId;
    global Datetime deploymentTaskJobEndTime;
    global Id deploymentTaskJobExecutionId;
    global Boolean hasDeploymentTaskOnlyJob;
    global Boolean isIntermediateEnvironmentStory;
    global Id promotedUserStoryId;
    global Id promotionId;
    global Datetime promotionLastModified;
    global String promotionMethod;
    global Id userStoryId;
    global String userStoryName;
    global PromotedIntoSourceMeta() {

    }
}
global class Request implements copado.CopadoServiceRequest {
    global Id environmentId;
    global Boolean includeHiddenStories;
    global Id pipelineId;
    global Request() {

    }
}
global class StoryEntry {
    @AuraEnabled
    global String blockReason;
    @AuraEnabled
    global Id bundleParentId;
    @AuraEnabled
    global String bundleParentName;
    @AuraEnabled
    global String bundlePromotionMethod;
    @AuraEnabled
    global Boolean cascadeExcluded;
    @AuraEnabled
    global Datetime commitTime;
    @AuraEnabled
    global Boolean contributesToGitCutoff;
    @AuraEnabled
    global Datetime createdDate;
    @AuraEnabled
    global Id deployJobExecutionId;
    @AuraEnabled
    global String entryType;
    @AuraEnabled
    global Boolean excludeFromCbm;
    @AuraEnabled
    global Boolean fallbackToPreviousRow;
    @AuraEnabled
    global Boolean isBlocker;
    @AuraEnabled
    global Boolean isBundleChild;
    @AuraEnabled
    global Boolean isBundleParent;
    @AuraEnabled
    global Boolean isRepositionedEntry;
    @AuraEnabled
    global Boolean isSelectable;
    @AuraEnabled
    global Boolean isTaskOnlyGroup;
    @AuraEnabled
    global Boolean isVisible;
    @AuraEnabled
    global Datetime lastCommitDate;
    @AuraEnabled
    global Id lastCommitJobExecutionId;
    @AuraEnabled
    global Integer mergeOrder;
    @AuraEnabled
    global String positionSource;
    @AuraEnabled
    global Datetime positionTimestamp;
    @AuraEnabled
    global Boolean promoteChange;
    @AuraEnabled
    global Id promotionId;
    @AuraEnabled
    global String promotionMethod;
    @AuraEnabled
    global Integer sortIndex;
    @AuraEnabled
    global Id userStoryId;
    @AuraEnabled
    global String userStoryName;
    @AuraEnabled
    global String userStoryStatus;
    @AuraEnabled
    global String userStoryTitle;
    @AuraEnabled
    global List<String> warningMessage;
    global StoryEntry() {

    }
}
global class TimelineResult implements copado.CopadoServiceResult {
    @AuraEnabled
    global String errorCode;
    @AuraEnabled
    global String errorMessage;
    @AuraEnabled
    global Id nextEnvironmentId;
    @AuraEnabled
    global List<copado.PitForwardPromotionModels.StoryEntry> orderedStories;
    @AuraEnabled
    global Boolean pitAvailable;
    @AuraEnabled
    global Id sourceEnvironmentId;
    @AuraEnabled
    global Integer totalVisibleCount;
    @AuraEnabled
    global List<copado.Promotions.ServiceError> warnings;
    global TimelineResult() {

    }
}
}
