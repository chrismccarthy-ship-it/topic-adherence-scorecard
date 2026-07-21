/**
 * TopicAdherenceScorecardController
 *
 * Backing controller for the topicAdherenceScorecard LWC.
 *
 * Responsibilities:
 *   1. Load the target Agentforce agent's topics, instructions, and actions
 *      from BotDefinition and (if present in the org) the GenAi* metadata
 *      objects.
 *   2. Hand the transcript + agent config to a Flow that invokes the
 *      Prompt Template containing the scoring rubric.
 *   3. Parse the Flow's JSON output into a typed wrapper the LWC can render.
 *
 * Why dynamic Schema describe instead of static SOQL?
 *   The Agentforce metadata object/field names have evolved across releases
 *   (GenAiPluginDefinition vs GenAiPlugin, GenAiFunctionDef vs
 *   GenAiPluginFunction, etc.) and not every org has them provisioned.
 *   This controller checks at runtime which objects + fields exist, builds
 *   the SOQL from whatever's actually available, and gracefully degrades
 *   if nothing's there — letting the Prompt Template evaluate against
 *   transcript + criteria alone.
 */
public with sharing class TopicAdherenceScorecardController {

    @TestVisible
    private static final String FLOW_OUTPUT_VAR = 'scorecardJson';

    private static final String IN_TRANSCRIPT       = 'transcript';
    private static final String IN_AGENT_CONFIG     = 'agentConfigJson';
    private static final String IN_PROMPT_TEMPLATE  = 'promptTemplateApiName';
    private static final String IN_RECORD_ID        = 'recordId';

    // Candidate API names — checked in order at runtime. The first one
    // that exists in the org wins. Add more as new Agentforce releases
    // change the schema.
    private static final List<String> PLUGIN_OBJECT_CANDIDATES = new List<String>{
        'GenAiPluginDefinition',
        'GenAiPlugin'
    };
    private static final List<String> FUNCTION_OBJECT_CANDIDATES = new List<String>{
        'GenAiFunctionDef',
        'GenAiPluginFunctionDef',
        'GenAiPluginFunction',
        'GenAiFunction'
    };

    // ═════════════════════════════════════════════════════════════════════
    // PUBLIC ENTRY POINT
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static ScorecardResult evaluateAdherence(
        String recordId,
        String transcript,
        String promptTemplateApiName,
        String agentApiName,
        String flowApiName
    ) {
        try {
            validateInputs(transcript, promptTemplateApiName, agentApiName, flowApiName);

            AgentConfig agentConfig = loadAgentConfig(agentApiName);
            String agentConfigJson  = JSON.serialize(agentConfig);

            String scorecardJson = invokeEvaluatorFlow(
                flowApiName,
                recordId,
                transcript,
                agentConfigJson,
                promptTemplateApiName
            );

            return parseScorecard(scorecardJson, agentConfig);

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(
                'Adherence evaluation failed: ' + e.getMessage()
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // INPUT VALIDATION
    // ═════════════════════════════════════════════════════════════════════

    private static void validateInputs(
        String transcript,
        String promptTemplateApiName,
        String agentApiName,
        String flowApiName
    ) {
        List<String> missing = new List<String>();
        if (String.isBlank(transcript))            missing.add('transcript');
        if (String.isBlank(promptTemplateApiName)) missing.add('prompt template');
        if (String.isBlank(agentApiName))          missing.add('agent');
        if (String.isBlank(flowApiName))           missing.add('evaluator flow');
        if (!missing.isEmpty()) {
            throw new AuraHandledException(
                'Missing required input: ' + String.join(missing, ', ')
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // AGENT METADATA LOADER (dynamic — survives schema changes)
    // ═════════════════════════════════════════════════════════════════════

    @TestVisible
    private static AgentConfig loadAgentConfig(String agentApiName) {
        AgentConfig cfg = new AgentConfig();
        cfg.agentApiName = agentApiName;
        cfg.topics       = new List<TopicConfig>();

        // BotDefinition is the one stable object name. Build the field
        // list dynamically so we only request fields that exist + are
        // accessible to the running user.
        Set<String> botFields = describeAccessibleFields(
            'BotDefinition',
            new Set<String>{ 'Id', 'DeveloperName', 'MasterLabel', 'Description', 'Type' }
        );

        // DeveloperName + Id are guaranteed; add them defensively.
        botFields.add('Id');
        botFields.add('DeveloperName');

        String botSoql =
            'SELECT ' + String.join(new List<String>(botFields), ', ') +
            ' FROM BotDefinition' +
            ' WHERE DeveloperName = :agentApiName' +
            ' WITH USER_MODE' +
            ' LIMIT 1';

        List<SObject> bots;
        try {
            bots = Database.query(botSoql);
        } catch (Exception e) {
            throw new AuraHandledException(
                'Could not query BotDefinition: ' + e.getMessage()
            );
        }
        if (bots.isEmpty()) {
            throw new AuraHandledException(
                'Agent not found: ' + agentApiName +
                '. Verify the BotDefinition DeveloperName.'
            );
        }
        SObject bot = bots[0];
        cfg.agentLabel       = (String) safeGet(bot, 'MasterLabel');
        cfg.agentDescription = (String) safeGet(bot, 'Description');
        Id botId             = (Id)     bot.get('Id');

        // Resolve which plugin/function objects exist in this org.
        String pluginObject   = firstExistingObject(PLUGIN_OBJECT_CANDIDATES);
        String functionObject = firstExistingObject(FUNCTION_OBJECT_CANDIDATES);

        if (pluginObject == null) {
            // Org doesn't have Agentforce topic metadata — return what we have.
            // The Flow can still evaluate against transcript + criteria.
            return cfg;
        }

        loadTopics(cfg, botId, pluginObject, functionObject);
        return cfg;
    }

    /**
     * Loads topics (plugins) + their child functions/actions. Catches any
     * residual schema mismatch so an unexpected field rename can't break
     * the whole evaluation — we'll just have less detail in the agent
     * config sent to the LLM.
     */
    private static void loadTopics(
        AgentConfig cfg, Id botId, String pluginObject, String functionObject
    ) {
        // Find the foreign-key field on the plugin object that points to BotDefinition.
        // It's typically BotDefinitionId, but check defensively.
        String botFkField = findLookupFieldTo(pluginObject, 'BotDefinition');
        if (botFkField == null) return;

        Set<String> pluginFields = describeAccessibleFields(
            pluginObject,
            new Set<String>{ 'Id', 'DeveloperName', 'MasterLabel', 'Description', botFkField }
        );
        pluginFields.add('Id');
        pluginFields.add(botFkField);

        String pluginSoql =
            'SELECT ' + String.join(new List<String>(pluginFields), ', ') +
            ' FROM ' + pluginObject +
            ' WHERE ' + botFkField + ' = :botId' +
            ' WITH USER_MODE' +
            ' LIMIT 200';

        List<SObject> plugins;
        try {
            plugins = Database.query(pluginSoql);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Plugin query failed (' + pluginObject + '): ' + e.getMessage());
            return;
        }

        // If we found a function object, prepare to bulk-load its records
        // keyed by the plugin foreign key.
        Map<Id, List<SObject>> functionsByPlugin = new Map<Id, List<SObject>>();
        String functionFkField = null;
        if (functionObject != null) {
            functionFkField = findLookupFieldTo(functionObject, pluginObject);
            if (functionFkField != null) {
                Set<String> fnFields = describeAccessibleFields(
                    functionObject,
                    new Set<String>{ 'Id', 'DeveloperName', 'MasterLabel', 'Description', functionFkField }
                );
                fnFields.add('Id');
                fnFields.add(functionFkField);

                Set<Id> pluginIds = (new Map<Id, SObject>(plugins)).keySet();
                String fnSoql =
                    'SELECT ' + String.join(new List<String>(fnFields), ', ') +
                    ' FROM ' + functionObject +
                    ' WHERE ' + functionFkField + ' IN :pluginIds' +
                    ' WITH USER_MODE' +
                    ' LIMIT 2000';

                try {
                    for (SObject fn : Database.query(fnSoql)) {
                        Id parentId = (Id) fn.get(functionFkField);
                        if (!functionsByPlugin.containsKey(parentId)) {
                            functionsByPlugin.put(parentId, new List<SObject>());
                        }
                        functionsByPlugin.get(parentId).add(fn);
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN,
                        'Function query failed (' + functionObject + '): ' + e.getMessage());
                }
            }
        }

        for (SObject plugin : plugins) {
            TopicConfig topic = new TopicConfig();
            topic.apiName      = (String) safeGet(plugin, 'DeveloperName');
            topic.label        = (String) safeGet(plugin, 'MasterLabel');
            topic.instructions = (String) safeGet(plugin, 'Description');
            topic.actions      = new List<ActionConfig>();

            List<SObject> fns = functionsByPlugin.get((Id) plugin.get('Id'));
            if (fns != null) {
                for (SObject fn : fns) {
                    ActionConfig act = new ActionConfig();
                    act.apiName     = (String) safeGet(fn, 'DeveloperName');
                    act.label       = (String) safeGet(fn, 'MasterLabel');
                    act.description = (String) safeGet(fn, 'Description');
                    topic.actions.add(act);
                }
            }
            cfg.topics.add(topic);
        }
    }

    // ─── Schema helpers ──────────────────────────────────────────────────

    /**
     * Returns the first object name from `candidates` that exists in the
     * current org and is accessible. Null if none match.
     */
    private static String firstExistingObject(List<String> candidates) {
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        for (String name : candidates) {
            Schema.SObjectType t = globalDescribe.get(name);
            if (t != null && t.getDescribe().isAccessible()) {
                return name;
            }
        }
        return null;
    }

    /**
     * Intersect a wishlist of field API names with what actually exists
     * AND is accessible to the running user. Returns the safe subset.
     */
    private static Set<String> describeAccessibleFields(
        String objectName, Set<String> wishlist
    ) {
        Set<String> safe = new Set<String>();
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
        if (t == null) return safe;

        Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
        for (String wanted : wishlist) {
            Schema.SObjectField f = fields.get(wanted.toLowerCase());
            if (f != null && f.getDescribe().isAccessible()) {
                safe.add(wanted);
            }
        }
        return safe;
    }

    /**
     * Find the first reference field on `objectName` whose referenceTo
     * includes `targetObject`. Returns null if no such field exists.
     */
    private static String findLookupFieldTo(String objectName, String targetObject) {
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
        if (t == null) return null;

        Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
        for (Schema.SObjectField f : fields.values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (d.getType() == Schema.DisplayType.REFERENCE) {
                for (Schema.SObjectType ref : d.getReferenceTo()) {
                    if (ref.getDescribe().getName() == targetObject) {
                        return d.getName();
                    }
                }
            }
        }
        return null;
    }

    /** Get a field value defensively — returns null if the field isn't on the SObject. */
    private static Object safeGet(SObject record, String fieldName) {
        try {
            return record.get(fieldName);
        } catch (Exception e) {
            return null;
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // FLOW INVOCATION
    // ═════════════════════════════════════════════════════════════════════

    @TestVisible
    private static String invokeEvaluatorFlow(
        String flowApiName,
        String recordId,
        String transcript,
        String agentConfigJson,
        String promptTemplateApiName
    ) {
        Map<String, Object> params = new Map<String, Object>{
            IN_RECORD_ID       => recordId,
            IN_TRANSCRIPT      => transcript,
            IN_AGENT_CONFIG    => agentConfigJson,
            IN_PROMPT_TEMPLATE => promptTemplateApiName
        };

        Flow.Interview interview;
        try {
            interview = Flow.Interview.createInterview(flowApiName, params);
        } catch (Exception e) {
            throw new AuraHandledException(
                'Could not create Flow "' + flowApiName + '": ' + e.getMessage()
            );
        }

        try {
            interview.start();
        } catch (Exception e) {
            throw new AuraHandledException(
                'Flow "' + flowApiName + '" failed: ' + e.getMessage()
            );
        }

        Object raw = interview.getVariableValue(FLOW_OUTPUT_VAR);
        if (raw == null) {
            throw new AuraHandledException(
                'Flow "' + flowApiName + '" did not return a "' +
                FLOW_OUTPUT_VAR + '" output variable.'
            );
        }
        return String.valueOf(raw);
    }

    // ═════════════════════════════════════════════════════════════════════
    // RESPONSE PARSER
    // ═════════════════════════════════════════════════════════════════════

    @TestVisible
    private static ScorecardResult parseScorecard(String scorecardJson, AgentConfig agentConfig) {
        if (String.isBlank(scorecardJson)) {
            throw new AuraHandledException('Empty response from evaluator Flow.');
        }

        String cleaned = sanitizeLlmJson(scorecardJson);

        ScorecardResult result;
        try {
            result = (ScorecardResult) JSON.deserialize(cleaned, ScorecardResult.class);
        } catch (Exception e) {
            throw new AuraHandledException(
                'Could not parse scorecard JSON: ' + e.getMessage() +
                '\nSnippet near failure: ' + snippetAroundFailure(cleaned, e.getMessage())
            );
        }

        if (result == null) {
            throw new AuraHandledException('Evaluator Flow returned null scorecard.');
        }
        if (result.categories == null) {
            result.categories = new List<ScoreCategory>();
        }

        Integer passed = 0, partial = 0, failed = 0;
        for (ScoreCategory cat : result.categories) {
            if (cat.items == null) continue;
            for (ScoreItem item : cat.items) {
                if (item.status == 'passed')  passed++;
                else if (item.status == 'partial') partial++;
                else                                failed++;
            }
        }
        result.passedCount  = passed;
        result.partialCount = partial;
        result.failedCount  = failed;
        result.evaluatedAt  = Datetime.now().format('MMM d, yyyy h:mm a');
        if (String.isBlank(result.modelUsed)) result.modelUsed = '';

        return result;
    }

    /**
     * LLMs frequently emit JSON with cosmetic problems that would otherwise
     * crash a strict parser. Strip the common ones in priority order:
     *   1. Markdown code fences (```json ... ```)
     *   2. Whitespace before the first { or [
     *   3. Smart quotes inside string values (curly " " ' ')
     *   4. Mis-escaped quote runs (\"\" → ", literal \" before value openers)
     *   5. Trailing commas before } or ]
     */
    @TestVisible
    private static String sanitizeLlmJson(String raw) {
        if (String.isBlank(raw)) return raw;
        String s = raw.trim();

        // Strip ``` fences (with or without "json" language tag).
        if (s.startsWith('```')) {
            Integer nl = s.indexOf('\n');
            if (nl > 0) s = s.substring(nl + 1);
            Integer closing = s.lastIndexOf('```');
            if (closing >= 0) s = s.substring(0, closing);
            s = s.trim();
        }

        // Find the first { or [ — anything before it is preamble noise.
        Integer firstBrace = s.indexOf('{');
        Integer firstBracket = s.indexOf('[');
        Integer start = -1;
        if (firstBrace >= 0 && firstBracket >= 0) {
            start = Math.min(firstBrace, firstBracket);
        } else if (firstBrace >= 0) {
            start = firstBrace;
        } else if (firstBracket >= 0) {
            start = firstBracket;
        }
        if (start > 0) s = s.substring(start);

        // Normalize smart quotes to ASCII.
        s = s.replace('\u201C', '"')
             .replace('\u201D', '"')
             .replace('\u2018', '\'')
             .replace('\u2019', '\'');

        // Quote-escape repair passes — most common LLM mistakes when the
        // value contains quoted dialogue from a transcript:
        //
        //   "evidence": \"\"He said hello\"\""
        //          ↓ collapse \"\" → "
        //   "evidence": "He said hello"
        //
        // Run repeatedly because some models produce nested-bad escaping.
        Integer guard = 0;
        while (s.contains('\\"\\"') && guard++ < 6) {
            s = s.replace('\\"\\"', '"');
        }

        // Strip a literal \" that immediately follows a property colon —
        // i.e. the LLM put an escaped quote *before* the opening quote of
        // the value. Pattern: `: \""` → `: "`
        s = s.replaceAll(':\\s*\\\\"', ': "');

        // Same fix for the closing side — `\""` at end of a value.
        s = s.replaceAll('\\\\""', '"');

        // Strip trailing commas before } or ].
        s = s.replaceAll(',\\s*([}\\]])', '$1');

        return s;
    }

    /**
     * Pull a ~120 char window around a "line X, column Y" reference from
     * the parser error message, so the user sees what actually broke.
     */
    @TestVisible
    private static String snippetAroundFailure(String json, String errorMessage) {
        if (String.isBlank(json) || String.isBlank(errorMessage)) {
            return json != null ? json.abbreviate(200) : '';
        }
        Matcher m = Pattern.compile('line[:\\s]*(\\d+)').matcher(errorMessage.toLowerCase());
        if (!m.find()) return json.abbreviate(200);

        Integer targetLine;
        try {
            targetLine = Integer.valueOf(m.group(1));
        } catch (Exception e) {
            return json.abbreviate(200);
        }

        List<String> lines = json.split('\n');
        if (targetLine < 1 || targetLine > lines.size()) return json.abbreviate(200);

        // Show the broken line plus one line of context on either side.
        Integer start = Math.max(0, targetLine - 2);
        Integer endIx = Math.min(lines.size() - 1, targetLine);
        List<String> window = new List<String>();
        for (Integer i = start; i <= endIx; i++) {
            window.add('L' + (i + 1) + ': ' + lines[i]);
        }
        return String.join(window, ' | ').abbreviate(400);
    }

    // ═════════════════════════════════════════════════════════════════════
    // WRAPPER CLASSES
    // ═════════════════════════════════════════════════════════════════════

    public class ScorecardResult {
        @AuraEnabled public Decimal overallScore;
        @AuraEnabled public String  summary;
        @AuraEnabled public String  modelUsed;
        @AuraEnabled public String  evaluatedAt;
        @AuraEnabled public Integer passedCount;
        @AuraEnabled public Integer partialCount;
        @AuraEnabled public Integer failedCount;
        @AuraEnabled public List<ScoreCategory> categories;
    }

    public class ScoreCategory {
        @AuraEnabled public String  key;
        @AuraEnabled public String  label;
        @AuraEnabled public String  iconName;
        @AuraEnabled public Decimal score;
        @AuraEnabled public List<ScoreItem> items;
    }

    public class ScoreItem {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  description;
        @AuraEnabled public String  status;
        @AuraEnabled public Decimal score;
        @AuraEnabled public String  reasoning;
        @AuraEnabled public String  evidence;
        @AuraEnabled public String  suggestedImprovement;
    }

    public class AgentConfig {
        public String agentApiName;
        public String agentLabel;
        public String agentDescription;
        public List<TopicConfig> topics;
    }

    public class TopicConfig {
        public String apiName;
        public String label;
        public String instructions;
        public List<ActionConfig> actions;
    }

    public class ActionConfig {
        public String apiName;
        public String label;
        public String description;
    }
}
