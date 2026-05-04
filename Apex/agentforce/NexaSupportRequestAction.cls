public with sharing class NexaSupportRequestAction {
    public class Request {
        @InvocableVariable(required=true)
        public String userMessage;

        @InvocableVariable
        public String customerEmail;
    }

    public class Response {
        @InvocableVariable
        public String responseMessage;

        @InvocableVariable
        public Boolean success;

        @InvocableVariable
        public Boolean waitingForEmail;
    }

    @InvocableMethod(label='Handle Nexa Support Request')
    public static List<Response> handle(List<Request> requests) {
        List<Response> results = new List<Response>();

        for (Request req : requests) {
            Response res = new Response();
            res.success = false;
            res.waitingForEmail = false;

            String lastCategory = null;
            String cleanUserMessage = req.userMessage;
            if (String.isNotBlank(req.userMessage) && req.userMessage.contains('||lastCategory:')) {
                Integer startIdx = req.userMessage.indexOf('||lastCategory:') + 15;
                Integer endIdx = req.userMessage.lastIndexOf('||');
                if (endIdx > startIdx) {
                    lastCategory = req.userMessage.substring(startIdx, endIdx).trim();
                    cleanUserMessage = req.userMessage.substring(0, req.userMessage.indexOf('||lastCategory:')).trim();
                }
            }

            if (String.isBlank(req.customerEmail)) {

                Interaction_Log__c pendingLog = new Interaction_Log__c();
                pendingLog.Query_Text__c = cleanUserMessage;
                pendingLog.Response_Summary__c = 'Awaiting customer email before support processing.';
                pendingLog.Source_Channel__c = NexaSupportConfig.SOURCE_CHANNEL_AGENTFORCE;
                pendingLog.Pending_Follow_Up_status__c = NexaSupportConfig.FOLLOW_UP_STATUS_PENDING;
                pendingLog.Pending_Follow_Up_Type__c = NexaSupportConfig.FOLLOW_UP_TYPE_CLARIFICATION;
                pendingLog.Correlation_Id__c = String.valueOf(Crypto.getRandomLong());
                pendingLog.Channel_Type__c = deriveChannelType('agentforce');
                pendingLog.Identity_Resolution_Status__c = 'Unknown';
                pendingLog.Interaction_Timestamp__c = DateTime.now();
                pendingLog.Resolution_Status__c = 'Unresolved';
                pendingLog.Customer_Sentiment__c = 'Neutral';

                insert pendingLog;

                res.waitingForEmail = true;
                res.responseMessage = NexaSupportConfig.MSG_PROVIDE_EMAIL;
                results.add(res);
                continue;
            }

            List<Contact> contacts = [
                SELECT Id, Name, Email, AccountId
                FROM Contact
                WHERE Email = :req.customerEmail
                LIMIT 1
            ];

            if (contacts.isEmpty()) {
                res.responseMessage = NexaSupportConfig.MSG_CONTACT_NOT_FOUND;
                results.add(res);
                continue;
            }

            CustomerInsightService.InsightResult insightResult = 
                CustomerInsightService.fetchInsight(contacts[0].Id);

            List<Interaction_Log__c> pendingLogs = [
                SELECT Id, Query_Text__c, Pending_Follow_Up_status__c, Pending_Follow_Up_Type__c
                FROM Interaction_Log__c
                WHERE Pending_Follow_Up_status__c = :NexaSupportConfig.FOLLOW_UP_STATUS_PENDING
                  AND Pending_Follow_Up_Type__c = :NexaSupportConfig.FOLLOW_UP_TYPE_CLARIFICATION
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];

            String issueToProcess = cleanUserMessage;

            if (!pendingLogs.isEmpty() && !String.isBlank(pendingLogs[0].Query_Text__c)) {
                issueToProcess = pendingLogs[0].Query_Text__c;

                pendingLogs[0].Contact__c = contacts[0].Id;
                pendingLogs[0].Identity_Resolution_Status__c = 'Matched Existing Customer';
                pendingLogs[0].Unified_Customer_Key__c = buildUnifiedCustomerKey(contacts[0]);
                if (String.isNotBlank(insightResult.unifiedCustomerId)) {
                    pendingLogs[0].Unified_Customer_Key__c = insightResult.unifiedCustomerId;
                }
                pendingLogs[0].Channel_Type__c = deriveChannelType('agentforce');
                pendingLogs[0].Pending_Follow_Up_Type__c = NexaSupportConfig.FOLLOW_UP_TYPE_CLARIFICATION;
                pendingLogs[0].Pending_Follow_Up_status__c = NexaSupportConfig.FOLLOW_UP_STATUS_COMPLETED;
                pendingLogs[0].Response_Summary__c = 'Customer email verified and original issue recovered for support processing.';
                update pendingLogs[0];
            } else {
                Interaction_Log__c completedLog = new Interaction_Log__c();
                completedLog.Contact__c = contacts[0].Id;
                completedLog.Query_Text__c = cleanUserMessage;
                completedLog.Source_Channel__c = NexaSupportConfig.SOURCE_CHANNEL_AGENTFORCE;
                completedLog.Channel_Type__c = deriveChannelType('agentforce');
                completedLog.Identity_Resolution_Status__c = 'Matched Existing Customer';
                completedLog.Unified_Customer_Key__c = buildUnifiedCustomerKey(contacts[0]);
                if (insightResult != null && String.isNotBlank(insightResult.unifiedCustomerId)) {
                    completedLog.Unified_Customer_Key__c = insightResult.unifiedCustomerId;
                }
                completedLog.Pending_Follow_Up_Type__c = NexaSupportConfig.FOLLOW_UP_TYPE_CLARIFICATION;
                completedLog.Pending_Follow_Up_Status__c = NexaSupportConfig.FOLLOW_UP_STATUS_COMPLETED;
                completedLog.Response_Summary__c = 'Customer email verified and issue processed through support flow.';
                completedLog.Interaction_Timestamp__c = DateTime.now();
                completedLog.Resolution_Status__c = 'Unresolved';
                completedLog.Customer_Sentiment__c = 'Neutral';
                insert completedLog;
            }

            String rawClassificationResponse =
                NexaPromptClassificationService.classifyCustomerMessage(issueToProcess);

            NexaClassificationParserV2.Response parsed =
                NexaClassificationParserV2.parseSingle(rawClassificationResponse);

            String detectedCategory = parsed != null ? parsed.category : null;
            Boolean wantsHumanSupport = parsed != null ? parsed.wantsHumanSupport : null;
            String issueNature = parsed != null ? parsed.issueNature : null;
            String classificationSummary = parsed != null ? parsed.summary : null;
            String detectedIntent = parsed != null ? parsed.intent : null;
            Boolean isFollowUp = parsed != null ? parsed.isFollowUp : false;

            System.debug('ACTION_PARSED_CATEGORY = ' + detectedCategory);
            System.debug('ACTION_PARSED_LAST_CATEGORY = ' + lastCategory);
            System.debug('ACTION_PARSED_IS_FOLLOWUP = ' + isFollowUp);

            if (wantsHumanSupport == true) {
                Integer openCaseCount = [
                    SELECT COUNT()
                    FROM Case
                    WHERE ContactId = :contacts[0].Id
                      AND Status != :NexaSupportConfig.CASE_STATUS_CLOSED
                ];

                if (openCaseCount >= 2) {
                    // ✅ CRITICAL: Vague request check FIRST (includes Escalation category)
                    if (String.isBlank(detectedCategory) || 
                        detectedCategory == 'General Inquiry' ||
                        detectedCategory == 'Escalation') {
                        res.success = true;
                        res.responseMessage = 'You currently have multiple open issues. Which issue do you want help with — billing, login, technical, or another issue? Is it urgent?';
                        results.add(res);
                        continue;
                    }
                    
                    // ✅ If we reach here, specific category EXISTS
                    Boolean isTechnicalPhysical = (detectedCategory == NexaSupportConfig.CATEGORY_TECHNICAL && 
                                                    issueNature == NexaSupportConfig.ISSUE_NATURE_PHYSICAL);
                    
                    if (isTechnicalPhysical) {
                        String msg = processSupportCase(
                            contacts[0], issueToProcess, detectedCategory,
                            wantsHumanSupport, issueNature, insightResult, cleanUserMessage
                        );
                        res.success = true;
                        res.responseMessage = msg;
                        results.add(res);
                        continue;
                    }
                    
                    String fullCategoryToQuery = detectedCategory;
                    if (detectedCategory == NexaSupportConfig.CATEGORY_TECHNICAL && String.isNotBlank(issueNature)) {
                        fullCategoryToQuery = detectedCategory + ' - ' + issueNature;
                    }
                    
                    Group humanSupportQueue = [
                        SELECT Id FROM Group
                        WHERE Type = 'Queue'
                        AND DeveloperName = :NexaSupportConfig.HUMAN_SUPPORT_QUEUE_DEV_NAME
                        LIMIT 1
                    ];
                    
                    List<Case> categoryCase = [
                        SELECT Id, CaseNumber, Status, Priority, Escalated__c, Issue_Category__c
                        FROM Case
                        WHERE ContactId = :contacts[0].Id
                          AND Status != :NexaSupportConfig.CASE_STATUS_CLOSED
                          AND Issue_Category__c = :fullCategoryToQuery
                        LIMIT 1
                    ];
                    
                    if (!categoryCase.isEmpty()) {
                        Case specificCase = categoryCase[0];
                        
                        if (specificCase.Escalated__c == true) {
                            res.success = true;
                            res.responseMessage = 'Your existing case ' + specificCase.CaseNumber + 
                                ' has already been escalated and our priority support team is actively working on it. You will be contacted soon.';
                            results.add(res);
                            continue;
                        } else {
                            specificCase.Priority = NexaSupportConfig.PRIORITY_HIGH;
                            specificCase.Escalated__c = true;
                            specificCase.OwnerId = humanSupportQueue.Id;
                            update specificCase;
                            
                            res.success = true;
                            res.responseMessage = 'We can see you have multiple open issues. Your case ' + specificCase.CaseNumber + 
                                ' has been escalated to our priority support team with high priority. They will review all your open issues and get back to you as soon as possible.';
                            results.add(res);
                            continue;
                        }
                    } else {
                        res.success = true;
                        res.responseMessage = 'We can see you have multiple open issues. Our priority support team has been notified and will review all your open issues and get back to you as soon as possible.';
                        results.add(res);
                        continue;
                    }
                    
                } else if (openCaseCount == 1) {
                    Group humanSupportQueue = [
                        SELECT Id FROM Group
                        WHERE Type = 'Queue'
                        AND DeveloperName = :NexaSupportConfig.HUMAN_SUPPORT_QUEUE_DEV_NAME
                        LIMIT 1
                    ];
                    List<Case> singleOpenCase = [
                        SELECT Id, CaseNumber, Status, Priority, Escalated__c, Issue_Category__c
                        FROM Case
                        WHERE ContactId = :contacts[0].Id
                          AND Status != :NexaSupportConfig.CASE_STATUS_CLOSED
                        LIMIT 1
                    ];

                    if (!singleOpenCase.isEmpty()) {
                        Case autoCase = singleOpenCase[0];
                        if (autoCase.Escalated__c == true) {
                            res.success = true;
                            res.responseMessage = 'Your existing case ' + autoCase.CaseNumber + ' has already been escalated and our priority support team is actively working on it. You will be contacted soon.';
                            results.add(res);
                            continue;
                        }
                        autoCase.Priority = NexaSupportConfig.PRIORITY_HIGH;
                        autoCase.Escalated__c = true;
                        autoCase.OwnerId = humanSupportQueue.Id;
                        update autoCase;
                        res.success = true;
                        res.responseMessage = 'We understand your issue is still unresolved. Your existing case ' + autoCase.CaseNumber + ' has been escalated to our priority support team. They will follow up with you as soon as possible.';
                        results.add(res);
                        continue;
                    }
                } else {
                    res.success = true;
                    res.responseMessage = 'We would be happy to connect you with our support team. Could you please tell us what type of issue you are facing — is it a billing concern, login issue, technical problem, or something else?';
                    results.add(res);
                    continue;
                }
            }

            if (String.isBlank(detectedCategory)) {
                res.success = false;
                res.responseMessage = NexaSupportConfig.MSG_UNSUPPORTED_REQUEST;
                results.add(res);
                continue;
            }

            Set<String> supportedCategories = new Set<String>{
                'Login', 'Billing', 'Technical', 'General Inquiry'
            };

            if (!supportedCategories.contains(detectedCategory)) {
                res.success = false;
                res.responseMessage = NexaSupportConfig.MSG_UNSUPPORTED_REQUEST;
                results.add(res);
                continue;
            }

            if (wantsHumanSupport == null) wantsHumanSupport = false;
            if (isFollowUp == null) isFollowUp = false;

            if (isFollowUp == true) {
                Integer openCaseCount = [
                    SELECT COUNT()
                    FROM Case
                    WHERE ContactId = :contacts[0].Id
                      AND Status != :NexaSupportConfig.CASE_STATUS_CLOSED
                ];

                if (openCaseCount == 0) {
                    res.success = true;
                    res.responseMessage = 'We could not find any open issues associated with your account. Could you please describe your issue so we can assist you?';
                    results.add(res);
                    continue;

                } else if (openCaseCount == 1) {
                    Group humanSupportQueue = [
                        SELECT Id FROM Group
                        WHERE Type = 'Queue'
                        AND DeveloperName = :NexaSupportConfig.HUMAN_SUPPORT_QUEUE_DEV_NAME
                        LIMIT 1
                    ];
                    List<Case> singleOpenCase = [
                        SELECT Id, CaseNumber, Status, Priority, Escalated__c, Issue_Category__c
                        FROM Case
                        WHERE ContactId = :contacts[0].Id
                          AND Status != :NexaSupportConfig.CASE_STATUS_CLOSED
                        LIMIT 1
                    ];
                    if (!singleOpenCase.isEmpty()) {
                        Case followUpCase = singleOpenCase[0];
                        String existingCategory = followUpCase.Issue_Category__c;

                        String effectiveCategory = String.isNotBlank(lastCategory) ? lastCategory : detectedCategory;

                        Boolean isNewCategory =
                            String.isNotBlank(effectiveCategory) &&
                            effectiveCategory != 'General Inquiry' &&
                            effectiveCategory != existingCategory;

                        if (isNewCategory) {
                            String msg = processSupportCase(
                                contacts[0], issueToProcess, effectiveCategory,
                                wantsHumanSupport, issueNature, insightResult, cleanUserMessage
                            );
                            res.success = true;
                            res.responseMessage = msg;
                            results.add(res);
                            continue;
                        }

                        if (followUpCase.Escalated__c == true) {
                            res.success = true;
                            res.responseMessage = 'Your existing case ' + followUpCase.CaseNumber + ' has already been escalated and our priority support team is actively working on it. You will be contacted soon.';
                            results.add(res);
                            continue;
                        }

                        followUpCase.Priority = NexaSupportConfig.PRIORITY_HIGH;
                        followUpCase.Escalated__c = true;
                        followUpCase.OwnerId = humanSupportQueue.Id;
                        update followUpCase;
                        res.success = true;
                        res.responseMessage = 'We understand your issue is still unresolved. Your existing case ' + followUpCase.CaseNumber + ' has been escalated to our priority support team with high priority. They will follow up with you as soon as possible.';
                        results.add(res);
                        continue;
                    }

                } else {
                    res.success = true;
                    res.responseMessage = 'You currently have multiple open issues. Which issue are you following up on — billing, login, technical, or another issue?';
                    results.add(res);
                    continue;
                }
            }

            String finalProcessingMessage = processSupportCase(
                contacts[0],
                issueToProcess,
                detectedCategory,
                wantsHumanSupport,
                issueNature,
                insightResult,
                cleanUserMessage
            );

            res.success = true;
            res.responseMessage = finalProcessingMessage;
            results.add(res);
        }

        return results;
    }

    private static String processSupportCase(
        Contact matchedContact,
        String issueToProcess,
        String detectedCategory,
        Boolean wantsHumanSupport,
        String issueNature,
        CustomerInsightService.InsightResult insightResult,
        String originalUserMessage
    ) {
        Boolean forceEscalationFromInsight = insightResult.forceEscalation;
        Boolean forceHighPriorityFromInsight = insightResult.forceHighPriority;
        Boolean fasterSupportPathFromInsight = insightResult.fasterSupportPath;
        String insightNote = insightResult.internalInsightNote;

        Group humanSupportQueue = [
            SELECT Id FROM Group
            WHERE Type = 'Queue'
            AND DeveloperName = :NexaSupportConfig.HUMAN_SUPPORT_QUEUE_DEV_NAME
            LIMIT 1
        ];

        Integer totalOpenCases = [
            SELECT COUNT()
            FROM Case
            WHERE ContactId = :matchedContact.Id
              AND Status != :NexaSupportConfig.CASE_STATUS_CLOSED
        ];

        String fullIssueCategory = detectedCategory;
        if (detectedCategory == NexaSupportConfig.CATEGORY_TECHNICAL && String.isNotBlank(issueNature)) {
            fullIssueCategory = detectedCategory + ' - ' + issueNature;
        }

        Boolean isTechnicalPhysical = (detectedCategory == NexaSupportConfig.CATEGORY_TECHNICAL && 
                                        issueNature == NexaSupportConfig.ISSUE_NATURE_PHYSICAL);

        if (!isTechnicalPhysical) {
            List<Case> existingCases = [
                SELECT Id, CaseNumber, Status, Priority, Escalated__c, Issue_Category__c
                FROM Case
                WHERE ContactId = :matchedContact.Id
                  AND Status != :NexaSupportConfig.CASE_STATUS_CLOSED
                  AND Issue_Category__c = :fullIssueCategory
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];

            if (!existingCases.isEmpty()) {
                Case existingCase = existingCases[0];

                if (existingCase.Escalated__c == true) {
                    Boolean explicitNewCase = originalUserMessage != null && (
                        originalUserMessage.toLowerCase().contains('different') ||
                        originalUserMessage.toLowerCase().contains('separate case') ||
                        originalUserMessage.toLowerCase().contains('new case') ||
                        originalUserMessage.toLowerCase().contains('another case')
                    );
                    if (!explicitNewCase) {
        return 'Your existing case ' + existingCase.CaseNumber + 
            ' has already been escalated and our priority support team is actively working on it. You will be contacted soon.';  // ✅ WITH CASE NUMBER
    }
                } else {
                    existingCase.Priority = NexaSupportConfig.PRIORITY_HIGH;
                    existingCase.Escalated__c = true;
                    existingCase.OwnerId = humanSupportQueue.Id;
                    update existingCase;

                    if (totalOpenCases >= 2) {
                        return 'We can see you have multiple open issues. A new support case has been created and immediately escalated to our priority support team. They will review all your open issues and get back to you as soon as possible.';
                    }
                    return 'Your existing case ' + existingCase.CaseNumber +
                        ' has been escalated to our human support team with high priority. They will assist you further with your ' + detectedCategory + ' issue.';
                }
            }
        }

        Boolean requiresImmediateEscalation = false;

        if (detectedCategory == NexaSupportConfig.CATEGORY_TECHNICAL && 
            issueNature == NexaSupportConfig.ISSUE_NATURE_PHYSICAL) {
            requiresImmediateEscalation = true;
        }
        else if (totalOpenCases >= 2) {
            Boolean isTechnicalRemote = (detectedCategory == NexaSupportConfig.CATEGORY_TECHNICAL && 
                                          issueNature == NexaSupportConfig.ISSUE_NATURE_REMOTE);
            if (!isTechnicalRemote) {
                requiresImmediateEscalation = true;
            }
        }

        if (totalOpenCases >= 1 && forceEscalationFromInsight) requiresImmediateEscalation = true;
        if (totalOpenCases >= 1 && fasterSupportPathFromInsight) requiresImmediateEscalation = true;

        if (detectedCategory == NexaSupportConfig.CATEGORY_TECHNICAL && 
            wantsHumanSupport == true) {
            requiresImmediateEscalation = true;
        }

        String caseSubject = 'Velyza Support - ' + fullIssueCategory;

        Case newCase = new Case();
        newCase.ContactId = matchedContact.Id;
        newCase.AccountId = matchedContact.AccountId;
        newCase.Subject = caseSubject;
        newCase.Description = issueToProcess;
        if (String.isNotBlank(insightNote)) {
            newCase.Description = (newCase.Description == null ? '' : newCase.Description + '\n\n')
                + 'Customer Insight: ' + insightNote;
        }
        newCase.Status = NexaSupportConfig.CASE_STATUS_NEW;
        newCase.Priority = (requiresImmediateEscalation || (totalOpenCases >= 1 && forceHighPriorityFromInsight))
            ? NexaSupportConfig.PRIORITY_HIGH
            : NexaSupportConfig.PRIORITY_MEDIUM;
        newCase.Issue_Category__c = fullIssueCategory;

        insert newCase;
        newCase = [SELECT Id, CaseNumber FROM Case WHERE Id = :newCase.Id];

        if (requiresImmediateEscalation) {
            newCase.Escalated__c = true;
            newCase.Priority = NexaSupportConfig.PRIORITY_HIGH;
            newCase.OwnerId = humanSupportQueue.Id;
            update newCase;

            if (totalOpenCases >= 2) {
                return 'We can see you have multiple open issues. A new support case has been created and immediately escalated to our priority support team. They will review all your open issues and get back to you as soon as possible.';
            }
            return 'A new support case ' + newCase.CaseNumber +
                ' has been created and escalated to our human support team with high priority.';
        }

        return 'A new support case ' + newCase.CaseNumber +
            ' has been created successfully. Our team will continue working on your request. We will follow up within 24 hours.';
    }

    private static String deriveChannelType(String source) {
        if (String.isBlank(source)) return 'Web';
        String s = source.trim().toLowerCase();
        if (s == 'web' || s == 'chat' || s == 'agentforce' || s == 'messaging') return 'Web';
        if (s == 'email') return 'Email';
        if (s == 'api' || s == 'portal' || s == 'integration') return 'API';
        if (s == 'voice' || s == 'call') return 'Voice';
        return 'Web';
    }

    private static String buildUnifiedCustomerKey(Contact c) {
        if (c == null) return null;
        if (c.AccountId != null) return 'ACC-' + c.AccountId + '_CON-' + c.Id;
        return 'CON-' + c.Id;
    }
}