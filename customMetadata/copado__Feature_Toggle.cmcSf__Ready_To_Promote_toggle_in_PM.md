<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>Show Ready To Promote Only toggle</label>
    <protected>false</protected>
    <values>
        <field>copado__Custom_Permission_Name__c</field>
        <value xsi:type="xsd:string">AccessShowReadyToPromoteOnlyToggleFeature</value>
    </values>
    <values>
        <field>copado__Feature_Toggle_Group__c</field>
        <value xsi:type="xsd:string">copado__CI_CD</value>
    </values>
    <values>
        <field>copado__Full_Description__c</field>
        <value xsi:type="xsd:string">&lt;p&gt;This setting controls the availability of the &lt;strong&gt;&quot;Show Ready to Promote Only&quot;&lt;/strong&gt; toggle within the Pipeline Manager for this specific persona. By enabling this feature, you provide users with an option that allows them to instantly clean up their view.&lt;/p&gt;&lt;br&gt;
&lt;p&gt;When this toggle is on, the Pipeline Manager displays only the user stories that have been explicitly flagged as &lt;strong&gt;&quot;Ready To Promote&quot;&lt;/strong&gt;, ensuring that Release Managers or Developers don&apos;t accidentally promote work that is still in progress.&lt;/p&gt;&lt;br&gt;
&lt;p&gt;If this setting is disabled, the toggle will be hidden entirely for the persona in the Pipeline Manager page, and the Pipeline Manager will default to showing only user stories flagged as &lt;strong&gt;&quot;Ready To Promote&quot;.&lt;/strong&gt;&lt;/p&gt;&lt;br&gt;
&lt;p&gt;&lt;strong&gt;The following pages in Copado will be affected by this change:&lt;/strong&gt;&lt;/p&gt;
&lt;ul&gt;
&lt;li&gt;SFP Pipeline Manager&lt;/li&gt;
&lt;/ul&gt;
&lt;p&gt;&lt;strong&gt;Help Docs:&lt;/strong&gt;&lt;/p&gt;
&lt;p&gt;&lt;a target=&quot;_blank&quot; rel=&quot;noopener noreferrer&quot; href=&quot; https://docs.copado.com/articles/#!copado-ci-cd-publication/pipeline-manager-for-salesforce-source-format-pipelines&quot;&gt;Pipeline Manager for Salesforce Source Format Pipelines (Copado Docs)&lt;/a&gt;&lt;/p&gt;</value>
    </values>
    <values>
        <field>copado__Order__c</field>
        <value xsi:type="xsd:double">4.0</value>
    </values>
    <values>
        <field>copado__Short_Description__c</field>
        <value xsi:type="xsd:string">Controls the visibility of the &apos;Show Ready to Promote Only&apos; toggle in the Pipeline Manager&apos;s environment page.</value>
    </values>
</CustomMetadata>
