public with sharing class PineconeRAGSearchAction {
    public class Request {
        @InvocableVariable(required=true)
        public String userQuery;
    }

    public class Response {
        @InvocableVariable
        public String ragAnswer;

        @InvocableVariable
        public Boolean answerFound;

        @InvocableVariable
        public String confidence;
    }

    @InvocableMethod(label='Search Pinecone Knowledge Base'
                     description='Searches Velyza FAQ knowledge base using semantic RAG search')
    public static List<Response> searchKnowledge(List<Request> requests) {
        List<Response> results = new List<Response>();

        for(Request req : requests) {
            Response res = new Response();

            try {
                // Pinecone RAG search
                PineconeSearchService.SearchResult searchResult =
                    PineconeSearchService.searchFAQs(req.userQuery, 3);

                if(searchResult.success && !searchResult.matches.isEmpty()) {

                    PineconeSearchService.FAQMatch topMatch = searchResult.matches[0];

                    if(topMatch.confidence == 'HIGH' || topMatch.confidence == 'MEDIUM') {
                        
                        // Grounded context banao
                        String groundedContext = PineconeSearchService.buildGroundedContext(searchResult);

                        res.answerFound = true;
                        res.confidence = topMatch.confidence;
                        res.ragAnswer = groundedContext;

                    } else {
                        res.answerFound = false;
                        res.confidence = 'LOW';
                        res.ragAnswer = '';
                    }

                } else {
                    res.answerFound = false;
                    res.confidence = 'NONE';
                    res.ragAnswer = '';
                }

            } catch(Exception e) {
                System.debug('RAG Search Error: ' + e.getMessage());
                res.answerFound = false;
                res.confidence = 'ERROR';
                res.ragAnswer = '';
            }

            results.add(res);
        }

        return results;
    }
}