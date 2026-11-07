/*
This file is generated and isn't the actual source code for this
managed global class.
This read-only file shows the class's global constructors,
methods, variables, and properties.
To enable code to compile, all methods return null.
*/
global class GetFieldSetAction {
    global GetFieldSetAction() {

    }
    @InvocableMethod(label='Get Field Set Members' description='Returns Schema field set members without Metadata API access.')
    global static List<copado.GetFieldSetAction.Response> execute(List<copado.GetFieldSetAction.Request> requests) {
        return null;
    }
global class Request {
    @InvocableVariable( required=true)
    global String fieldSetName;
    @InvocableVariable( required=true)
    global String objectApiName;
    global Request() {

    }
}
global class Response {
    @InvocableVariable( required=false)
    global String label;
    @InvocableVariable( required=false)
    global String membersJson;
    @InvocableVariable( required=false)
    global String name;
    global Response() {

    }
}
}
