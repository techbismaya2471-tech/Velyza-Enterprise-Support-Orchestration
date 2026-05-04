public with sharing class PineconeUploaderService {

    // ✅ APNI VALUES YAHAN HAIN
    private static final String PINECONE_API_KEY ='pcsk_4ZzpCr_SUEoB5W9hxDPEfH2woioVGayH2qy2bjgJTtEuiPrkhzpTJoA1p2uktNQYiLLEDF';
    private static final String PINECONE_HOST = 'https://velyza-rag-omucn5k.svc.aped-4627-b74a.pinecone.io';

    @future(callout=true)
    public static void uploadAllFAQs() {

        // Step 1: Static Resource se FAQ file padho
        StaticResource sr = [
            SELECT Body
            FROM StaticResource
            WHERE Name = 'VelyzaFAQDatabase'
            LIMIT 1
        ];

        String fileContent = sr.Body.toString();

        // Step 2: FAQs parse karo
        List<Map<String, String>> faqs = parseFAQs(fileContent);

        System.debug('Total FAQs found: ' + faqs.size());

        // Step 3: Batches me upload karo
        Integer uploadCount = 0;
        List<Map<String, String>> batch = new List<Map<String, String>>();

        for(Map<String, String> faq : faqs) {
            batch.add(faq);

            if(batch.size() == 10) {
                uploadBatch(batch);
                batch = new List<Map<String, String>>();
                uploadCount += 10;
                System.debug('Uploaded: ' + uploadCount + ' FAQs');
            }
        }

        // Remaining FAQs
        if(!batch.isEmpty()) {
            uploadBatch(batch);
            uploadCount += batch.size();
        }

        System.debug('✅ Total uploaded: ' + uploadCount + ' FAQs to Pinecone!');
    }

    // ✅ FAQ text parse karo
    private static List<Map<String, String>> parseFAQs(String content) {
        List<Map<String, String>> faqs = new List<Map<String, String>>();

        List<String> chunks = content.split('---------------------------------');

        for(String chunk : chunks) {
            chunk = chunk.trim();
            if(String.isBlank(chunk)) continue;
            if(!chunk.contains('FAQ_ID:')) continue;

            Map<String, String> faq = new Map<String, String>();

            List<String> lines = chunk.split('\n');

            for(String line : lines) {
                line = line.trim();
                if(String.isBlank(line)) continue;

                if(line.startsWith('Category:')) {
                    faq.put('category', line.substringAfter('Category:').trim());
                } else if(line.startsWith('FAQ_ID:')) {
                    faq.put('id', line.substringAfter('FAQ_ID:').trim());
                } else if(line.startsWith('Question:')) {
                    faq.put('question', line.substringAfter('Question:').trim());
                } else if(line.startsWith('Answer:')) {
                    faq.put('answer', line.substringAfter('Answer:').trim());
                } else if(line.startsWith('Keywords:')) {
                    faq.put('keywords', line.substringAfter('Keywords:').trim());
                }
            }

            if(faq.containsKey('id') && faq.containsKey('question') && faq.containsKey('answer')) {
                faqs.add(faq);
            }
        }

        return faqs;
    }

    // ✅ Batch upload - Manual JSON (fixes _id issue)
    private static void uploadBatch(List<Map<String, String>> batch) {

        List<String> recordJsonList = new List<String>();

        for(Map<String, String> faq : batch) {

            // Text content for embedding
            String textContent = 'Category: ' + escapeJson(faq.get('category')) +
                               '. Question: ' + escapeJson(faq.get('question')) +
                               '. Answer: ' + escapeJson(faq.get('answer')) +
                               '. Keywords: ' + escapeJson(faq.get('keywords'));

            // Manual JSON record banao (_id fix)
           String recordJson = '{'
                        + '"_id":"' + escapeJson(faq.get('id')) + '",'
                        + '"text":"' + textContent + '",'
                        + '"category":"' + escapeJson(faq.get('category')) + '",'
                        + '"faq_id":"' + escapeJson(faq.get('id')) + '",'
                        + '"question":"' + escapeJson(faq.get('question')) + '",'
                        + '"answer":"' + escapeJson(faq.get('answer')) + '",'
                        + '"keywords":"' + escapeJson(faq.get('keywords')) + '"'
                    + '}';
            recordJsonList.add(recordJson);
        }

        // Final request body
       // String requestBody = '{"records":[' + String.join(recordJsonList, ',') + ']}';
       String requestBody = String.join(recordJsonList, '\n');

        // HTTP Request
        HttpRequest req = new HttpRequest();
        req.setEndpoint(PINECONE_HOST + '/records/namespaces/velyza-faqs/upsert');
        req.setMethod('POST');
        req.setHeader('Api-Key', PINECONE_API_KEY);
        //req.setHeader('Content-Type', 'application/json');
        req.setHeader('Content-Type', 'application/x-ndjson');
        req.setHeader('X-Pinecone-API-Version', '2025-04');
        System.debug('REQUEST BODY: ' + requestBody.substring(0, Math.min(500, requestBody.length())));
        req.setBody(requestBody);
        req.setTimeout(120000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        System.debug('Pinecone Response: ' + res.getStatusCode() + ' - ' + res.getBody());

        if(res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            System.debug('✅ Batch uploaded successfully!');
        } else {
            System.debug('❌ Upload failed: ' + res.getBody());
        }
    }

    // ✅ JSON special characters escape karo
    private static String escapeJson(String input) {
        if(input == null) return '';
        input = input.replace('\\', '\\\\');
        input = input.replace('"', '\\"');
        input = input.replace('\n', '\\n');
        input = input.replace('\r', '\\r');
        input = input.replace('\t', '\\t');
        return input;
    }
}