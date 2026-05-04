public with sharing class PineconeSearchService {
   

    //  private static final String PINECONE_API_KEY ='pcsk_4ZzpCr_SUEoB5W9hxDPEfH2woioVGayH2qy2bjgJTtEuiPrkhzpTJoA1p2uktNQYiLLEDF';
    // private static final String PINECONE_HOST = 'https://velyza-rag-omucn5k.svc.aped-4627-b74a.pinecone.io';
    private static Agent_Api_Config__mdt config = Agent_Api_Config__mdt.getInstance('Velyza_Config');
    private static final String PINECONE_API_KEY = config.Pinecone_Api_Key__c;
    private static final String PINECONE_HOST = config.Pinecone_Host__c;

    // ✅ Main search method - Customer query se relevant FAQs dhundho
    public static SearchResult searchFAQs(String userQuery, Integer topK) {
        
        SearchResult result = new SearchResult();
        
        try {
            // Pinecone search request
           String requestBody = '{'
                    + '"query":{"top_k":' + topK + ',"inputs":{"text":"' + escapeJson(userQuery) + '"}}'
                + '}';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(PINECONE_HOST + '/records/namespaces/velyza-faqs/search');
            req.setMethod('POST');
            req.setHeader('Api-Key', PINECONE_API_KEY);
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('X-Pinecone-API-Version', '2025-04');
            req.setBody(requestBody);
            req.setTimeout(30000);

            Http http = new Http();
            HttpResponse res = http.send(req);

            System.debug('Search Response: ' + res.getStatusCode() + ' - ' + res.getBody());

            if(res.getStatusCode() == 200) {
                result = parseSearchResponse(res.getBody());
                result.success = true;
            } else {
                result.success = false;
                result.errorMessage = 'Search failed: ' + res.getBody();
            }

        } catch(Exception e) {
            result.success = false;
            result.errorMessage = e.getMessage();
            System.debug('Search Error: ' + e.getMessage());
        }

        return result;
    }

    // ✅ Search response parse karo
    private static SearchResult parseSearchResponse(String responseBody) {
        SearchResult result = new SearchResult();
        result.matches = new List<FAQMatch>();

        try {
            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            Map<String, Object> resultMap = (Map<String, Object>) response.get('result');
            List<Object> results = (List<Object>) resultMap.get('hits');

            if(results != null) {
                for(Object item : results) {
                    Map<String, Object> match = (Map<String, Object>) item;
                    
                    FAQMatch faqMatch = new FAQMatch();
                    //faqMatch.score = (Decimal) match.get('score');
                    faqMatch.score = (Decimal) match.get('_score');
                    
                    // Fields directly in record
                    Map<String, Object> fields = (Map<String, Object>) match.get('fields');
                    if(fields != null) {
                        faqMatch.faqId = (String) fields.get('faq_id');
                        faqMatch.category = (String) fields.get('category');
                        faqMatch.question = (String) fields.get('question');
                        faqMatch.answer = (String) fields.get('answer');
                        faqMatch.keywords = (String) fields.get('keywords');
                    }

                    // Confidence level set karo
                    // if(faqMatch.score >= 0.85) {
                    //     faqMatch.confidence = 'HIGH';
                    // } else if(faqMatch.score >= 0.70) {
                    //     faqMatch.confidence = 'MEDIUM';
                    // } else {
                    //     faqMatch.confidence = 'LOW';
                    // }
                    if(faqMatch.score >= 0.40) {
                        faqMatch.confidence = 'HIGH';
                    } else if(faqMatch.score >= 0.25) {
                        faqMatch.confidence = 'MEDIUM';
                    } else {
                        faqMatch.confidence = 'LOW';
                    }

                    result.matches.add(faqMatch);
                }
            }

        } catch(Exception e) {
            System.debug('Parse Error: ' + e.getMessage());
        }

        return result;
    }

    // ✅ Grounded context banao for Agentforce
    public static String buildGroundedContext(SearchResult searchResult) {
        if(searchResult == null || searchResult.matches == null || searchResult.matches.isEmpty()) {
            return '';
        }

        String context = 'RELEVANT KNOWLEDGE BASE ARTICLES:\n\n';
        Integer count = 1;

        for(FAQMatch match : searchResult.matches) {
            if(match.confidence == 'HIGH' || match.confidence == 'MEDIUM') {
                context += 'Article ' + count + ' [Confidence: ' + match.confidence + ']:\n';
                context += 'Category: ' + match.category + '\n';
                context += 'Q: ' + match.question + '\n';
                context += 'A: ' + match.answer + '\n';
                context += '[Source: ' + match.faqId + ']\n\n';
                count++;
            }
        }

        return context;
    }

    // ✅ JSON escape
    private static String escapeJson(String input) {
        if(input == null) return '';
        input = input.replace('\\', '\\\\');
        input = input.replace('"', '\\"');
        input = input.replace('\n', '\\n');
        input = input.replace('\r', '\\r');
        input = input.replace('\t', '\\t');
        return input;
    }

    // ✅ Result wrapper classes
    public class SearchResult {
        public Boolean success;
        public String errorMessage;
        public List<FAQMatch> matches;
        public String groundedContext;
        
        public SearchResult() {
            this.success = false;
            this.matches = new List<FAQMatch>();
        }
    }

    public class FAQMatch {
        public String faqId;
        public String category;
        public String question;
        public String answer;
        public String keywords;
        public Decimal score;
        public String confidence;
    }
}