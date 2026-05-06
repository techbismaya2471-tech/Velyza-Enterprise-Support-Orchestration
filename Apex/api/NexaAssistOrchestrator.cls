public with sharing class NexaAssistOrchestrator {
    public static NexaAssistResponse process(NexaAssistRequest req) {
        NexaAssistResponse res = new NexaAssistResponse();

        try {
            String token = AgentApiService.getAccessToken();

            String activeSessionId;
            if (String.isNotBlank(req.sessionId)) {
                activeSessionId = req.sessionId;
            } else {
                AgentApiService.SessionResponse session =
                    AgentApiService.createSession(token);
                activeSessionId = session.sessionId;
            }

            // sessionId + lastCategory append karo message mein
            String messageToSend = req.message;
            if (String.isNotBlank(req.lastCategory)) {
                messageToSend = req.message + ' ||lastCategory:' + req.lastCategory + '||';
            }
            // sessionId bhi append karo taaki Apex action use kar sake
            messageToSend = messageToSend + ' ||sessionId:' + activeSessionId + '||';

            String agentReply = AgentApiService.sendMessage(
                token,
                activeSessionId,
                messageToSend,
                1
            );

            res.success   = true;
            res.message   = agentReply;
            res.sessionId = activeSessionId;

            // Interaction_Log__c se case info query karo
            List<Interaction_Log__c> caseLogs = [
                SELECT Response_Summary__c
                FROM Interaction_Log__c
                WHERE Session_Id__c = :activeSessionId
                AND Correlation_Id__c LIKE 'CASE_CREATED_%'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            // List<Interaction_Log__c> caseLogs = [
            //     SELECT Response_Summary__c, Escalated__c, Last_Classifier_Used__c
            //     FROM Interaction_Log__c
            //     WHERE Session_Id__c = :activeSessionId
            //       AND Correlation_Id__c LIKE 'CASE_CREATED_%'
            //     ORDER BY CreatedDate DESC
            //     LIMIT 1
            // ];

            if (!caseLogs.isEmpty()) {
            String summary = caseLogs[0].Response_Summary__c;
            if (String.isNotBlank(summary) && summary.startsWith('{')) {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(summary);
            res.caseNumber = (String) parsed.get('caseNumber');
            res.escalated  = (Boolean) parsed.get('escalated');
            res.category   = (String) parsed.get('category');
    }
}

        } catch (Exception e) {
            res.success = false;
            res.message = e.getMessage();
        }

        return res;
    }
}