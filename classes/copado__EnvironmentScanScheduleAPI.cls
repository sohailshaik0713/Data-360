/*
This file is generated and isn't the actual source code for this
managed global class.
This read-only file shows the class's global constructors,
methods, variables, and properties.
To enable code to compile, all methods return null.
*/
@RestResource(urlMapping='/environment-scans/schedule')
global class EnvironmentScanScheduleAPI {
    global EnvironmentScanScheduleAPI() {

    }
    @HttpDelete
    global static copado.EnvironmentScanScheduleAPI.Response cancel() {
        return null;
    }
    @HttpPatch
    global static copado.EnvironmentScanScheduleAPI.Response reschedule(Id scheduledJobId, Id credentialId, String cronExpression) {
        return null;
    }
    @HttpPost
    global static copado.EnvironmentScanScheduleAPI.Response schedule(Id testId, Id credentialId, String cronExpression) {
        return null;
    }
global class Response {
    global Integer resultsDeleted;
    global Id scheduledJobId;
    global Integer scheduledJobsDeleted;
    global Id testId;
    global Response(Id scheduledJobId) {

    }
    global Response(Id scheduledJobId, Id testId, Integer scheduledJobsDeleted, Integer resultsDeleted) {

    }
}
}
