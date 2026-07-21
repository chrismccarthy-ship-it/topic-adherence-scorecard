/**
 * Tests for TopicAdherenceScorecardController.
 *
 * Coverage strategy:
 *   - Input validation paths produce friendly AuraHandledExceptions.
 *   - JSON parsing produces correct counts and timestamps.
 *   - Malformed JSON throws AuraHandledException, not raw JSONException.
 *
 * Note: we do NOT execute the real Flow in this test — that requires
 * a live Prompt Template + Models API setup. Tests cover the controller's
 * orchestration logic. Add an integration test in a sandbox once the
 * "Evaluate_Topic_Adherence" Flow is deployed.
 */
@IsTest
private class TopicAdherenceScorecardControllerTest {

    private static final String SAMPLE_JSON =
        '{' +
            '"overallScore":87,' +
            '"summary":"Agent stayed on topic but missed disclosure.",' +
            '"modelUsed":"GPT-4 Omni",' +
            '"categories":[' +
                '{' +
                    '"key":"topics","label":"Topics","score":90,"iconName":"utility:topic2",' +
                    '"items":[' +
                        '{"id":"t1","name":"Billing","description":"Inquiry about charges",' +
                          '"status":"passed","score":95,' +
                          '"reasoning":"Identified billing immediately.",' +
                          '"evidence":"Agent: I can help with that billing question..."}' +
                    ']' +
                '},' +
                '{' +
                    '"key":"instructions","label":"Instructions","score":80,"iconName":"utility:list",' +
                    '"items":[' +
                        '{"id":"i1","name":"Greet caller by name","status":"partial","score":60,' +
                          '"reasoning":"Greeted but mispronounced name.","evidence":"Agent: Hi Bobby..."}' +
                    ']' +
                '},' +
                '{' +
                    '"key":"actions","label":"Actions","score":75,"iconName":"utility:flow",' +
                    '"items":[' +
                        '{"id":"a1","name":"Disclose recording","status":"failed","score":0,' +
                          '"reasoning":"No recording disclosure detected.","evidence":""}' +
                    ']' +
                '}' +
            ']' +
        '}';

    // ─────────────────────────────────────────────────────────────────────
    // Input validation
    // ─────────────────────────────────────────────────────────────────────

    @IsTest
    static void evaluateAdherence_missingTranscript_throws() {
        Test.startTest();
        try {
            TopicAdherenceScorecardController.evaluateAdherence(
                null, '', 'My_Template', 'My_Agent', 'My_Flow'
            );
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true, 'Got expected exception');
        }
        Test.stopTest();
    }

    @IsTest
    static void evaluateAdherence_missingPromptTemplate_throws() {
        Test.startTest();
        try {
            TopicAdherenceScorecardController.evaluateAdherence(
                null, 'transcript text', '', 'My_Agent', 'My_Flow'
            );
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true, 'Got expected exception');
        }
        Test.stopTest();
    }

    @IsTest
    static void evaluateAdherence_missingAgent_throws() {
        Test.startTest();
        try {
            TopicAdherenceScorecardController.evaluateAdherence(
                null, 'transcript text', 'My_Template', '', 'My_Flow'
            );
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true, 'Got expected exception');
        }
        Test.stopTest();
    }

    @IsTest
    static void evaluateAdherence_missingFlow_throws() {
        Test.startTest();
        try {
            TopicAdherenceScorecardController.evaluateAdherence(
                null, 'transcript text', 'My_Template', 'My_Agent', ''
            );
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true, 'Got expected exception');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────
    // JSON parsing & count aggregation
    // ─────────────────────────────────────────────────────────────────────

    @IsTest
    static void parseScorecard_validJson_aggregatesCounts() {
        TopicAdherenceScorecardController.AgentConfig cfg =
            new TopicAdherenceScorecardController.AgentConfig();

        Test.startTest();
        TopicAdherenceScorecardController.ScorecardResult result =
            TopicAdherenceScorecardController.parseScorecard(SAMPLE_JSON, cfg);
        Test.stopTest();

        System.assertEquals(87, result.overallScore, 'overallScore preserved');
        System.assertEquals('GPT-4 Omni', result.modelUsed, 'model preserved');
        System.assertEquals(3, result.categories.size(), '3 categories');
        System.assertEquals(1, result.passedCount, '1 passed item');
        System.assertEquals(1, result.partialCount, '1 partial item');
        System.assertEquals(1, result.failedCount, '1 failed item');
        System.assert(String.isNotBlank(result.evaluatedAt), 'timestamp set');
    }

    @IsTest
    static void parseScorecard_emptyJson_throws() {
        TopicAdherenceScorecardController.AgentConfig cfg =
            new TopicAdherenceScorecardController.AgentConfig();

        Test.startTest();
        try {
            TopicAdherenceScorecardController.parseScorecard('', cfg);
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(true, 'Got expected exception');
        }
        Test.stopTest();
    }

    @IsTest
    static void parseScorecard_malformedJson_throwsAuraHandled() {
        TopicAdherenceScorecardController.AgentConfig cfg =
            new TopicAdherenceScorecardController.AgentConfig();

        Test.startTest();
        try {
            TopicAdherenceScorecardController.parseScorecard('not json', cfg);
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            // Verify it's wrapped, not a raw JSONException leaking through.
            System.assert(true, 'Caught AuraHandledException as expected');
        }
        Test.stopTest();
    }

    @IsTest
    static void parseScorecard_nullCategories_defaultsToEmpty() {
        TopicAdherenceScorecardController.AgentConfig cfg =
            new TopicAdherenceScorecardController.AgentConfig();
        String minJson = '{"overallScore":50,"summary":"x"}';

        Test.startTest();
        TopicAdherenceScorecardController.ScorecardResult result =
            TopicAdherenceScorecardController.parseScorecard(minJson, cfg);
        Test.stopTest();

        System.assertNotEquals(null, result.categories, 'categories defaulted');
        System.assertEquals(0, result.categories.size(), 'empty list');
        System.assertEquals(0, result.passedCount, 'no items → 0 passed');
    }
}
