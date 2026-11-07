/*
This file is generated and isn't the actual source code for this
managed global class.
This read-only file shows the class's global constructors,
methods, variables, and properties.
To enable code to compile, all methods return null.
*/
global class CICDExperienceSettingsAPI {
    global CICDExperienceSettingsAPI() {

    }
    global static List<copado.CICDExperienceSettingsAPI.ExperienceSetting> getExperiences(Id pipelineId) {
        return null;
    }
    global static void resetOverride(Id pipelineId, String experienceKey) {

    }
    global static void saveOverride(Id pipelineId, String experienceKey, Boolean enabled) {

    }
global class ExperienceSetting {
    @AuraEnabled
    global List<String> actions;
    @AuraEnabled
    global Boolean defaultEnabled;
    @AuraEnabled
    global Boolean enabled;
    @AuraEnabled
    global String experienceKey;
    @AuraEnabled
    global String experienceLabel;
    @AuraEnabled
    global Boolean isPipelineRelated;
    @AuraEnabled
    global String objectName;
    @AuraEnabled
    global Boolean overrideValue;
    global ExperienceSetting() {

    }
}
}
