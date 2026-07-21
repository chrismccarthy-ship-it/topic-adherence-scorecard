# Topic Adherence Scorecard

A custom Lightning Web Component that scores an **Agentforce voice-call transcript** against:

1. The evaluation rubric defined in a **Salesforce Prompt Template**
2. The target **Agentforce agent's topics, instructions, and actions** (from `BotDefinition` + `GenAiPluginDefinition` + `GenAiFunctionDef`)

The component ships with an overall score, pass/partial/failed tiles, and a four-tab breakdown — **Topics · Instructions · Actions · Evaluation Criteria** — where each scored item is expandable to reveal the LLM's reasoning and the transcript evidence that supports the verdict.

---

## Architecture

```
┌─────────────────────┐     imperative @AuraEnabled     ┌──────────────────────────────────┐
│  LWC                │ ──────────────────────────────▶ │  Apex                            │
│  topicAdherence-    │                                 │  TopicAdherenceScorecard-        │
│  Scorecard          │ ◀────────────────────────────── │  Controller.evaluateAdherence()  │
└─────────────────────┘       ScorecardResult JSON      └──────────────────────────────────┘
       ▲                                                            │
       │ @api transcript                                            │ Flow.Interview.start()
       │ (from Flow / parent)                                       ▼
                                                  ┌──────────────────────────────────┐
                                                  │  Autolaunched Flow               │
                                                  │  "Evaluate_Topic_Adherence"      │
                                                  │   • Invoke Prompt Template       │
                                                  │   • Return scorecardJson (Text)  │
                                                  └──────────────────────────────────┘
                                                                    │
                                                                    ▼
                                                       Models API → LLM
```

The Flow is the integration seam. Swap models, change the prompt-template version, or add pre/post-processing without touching Apex.

---

## File map

```
force-app/main/default/
├── classes/
│   ├── TopicAdherenceScorecardController.cls
│   ├── TopicAdherenceScorecardController.cls-meta.xml
│   ├── TopicAdherenceScorecardControllerTest.cls
│   └── TopicAdherenceScorecardControllerTest.cls-meta.xml
└── lwc/
    └── topicAdherenceScorecard/
        ├── topicAdherenceScorecard.html
        ├── topicAdherenceScorecard.js
        ├── topicAdherenceScorecard.css
        ├── topicAdherenceScorecard.js-meta.xml
        └── __tests__/
            └── topicAdherenceScorecard.test.js
```

---

## Prerequisites in the org

1. **Agentforce agent (`BotDefinition`)** with topics & actions configured.
2. **Prompt Template** containing the scoring rubric. It must accept two inputs:
   - `transcript` (Text) — the call transcript
   - `agentConfig` (Text, JSON blob) — serialized agent topics/instructions/actions
   And must instruct the model to return JSON matching the [scorecard schema](#scorecard-json-schema) below.
3. **Autolaunched Flow** (default name `Evaluate_Topic_Adherence`) — see [Flow contract](#flow-contract).

---

## Flow contract

The Apex controller calls the Flow synchronously. You define the Flow once in Flow Builder.

**Input variables (the Apex controller populates these):**

| Variable                | Type | Description                                              |
|-------------------------|------|----------------------------------------------------------|
| `recordId`              | Text | Optional context record (e.g. VoiceCall.Id)              |
| `transcript`            | Text | Raw transcript text                                      |
| `agentConfigJson`       | Text | Serialized JSON of the agent's topics + actions          |
| `promptTemplateApiName` | Text | DeveloperName of the Prompt Template to invoke           |

**Output variable (the Apex controller reads this):**

| Variable        | Type | Description                                                  |
|-----------------|------|--------------------------------------------------------------|
| `scorecardJson` | Text | JSON string matching the [scorecard schema](#scorecard-json-schema) |

**Inside the Flow:** drop in the **"Prompt Template"** invocable action, pass it `transcript` and `agentConfigJson` as inputs, store the LLM's response in `scorecardJson`. That's it.

---

## Scorecard JSON schema

The Prompt Template must instruct the LLM to emit JSON in this shape (the Apex deserializer is strict about field names):

```json
{
  "overallScore": 87,
  "summary": "Agent stayed on topic but missed disclosure step.",
  "modelUsed": "GPT-4 Omni",
  "categories": [
    {
      "key": "topics",
      "label": "Topics",
      "score": 90,
      "iconName": "utility:topic2",
      "items": [
        {
          "id": "topic_billing",
          "name": "Billing inquiry handling",
          "description": "Caller asked about charges on statement.",
          "status": "passed",
          "score": 95,
          "reasoning": "Agent identified billing topic immediately and routed correctly.",
          "evidence": "Agent: I can help with that billing question..."
        }
      ]
    },
    { "key": "instructions", "label": "Instructions", "score": 80, "items": [ /* ... */ ] },
    { "key": "actions",      "label": "Actions",      "score": 75, "items": [ /* ... */ ] },
    { "key": "criteria",     "label": "Evaluation Criteria", "score": 88, "items": [ /* ... */ ] }
  ]
}
```

- `status` ∈ `"passed" | "partial" | "failed"` (the LWC color-codes accordingly)
- `score` is 0–100 (the LWC renders it as a badge)
- `passedCount`, `partialCount`, `failedCount`, and `evaluatedAt` are populated **by Apex** — the LLM does not need to emit them.

---

## Deployment

```powershell
# 1. cd to the unzipped folder (must contain sfdx-project.json at root)
cd C:\path\to\topic-adherence-scorecard

# 2. Set default org (use your alias or username; do NOT use `sf org set default`)
sf config set target-org myOrgAlias

# 3. Deploy everything
sf project deploy start --source-dir force-app

# 4. Run tests
sf apex run test --class-names TopicAdherenceScorecardControllerTest --code-coverage --result-format human
```

If you only need to redeploy the LWC after edits:
```bash
sf project deploy start --source-dir force-app/main/default/lwc/topicAdherenceScorecard --ignore-conflicts
```

---

## Configuration in App Builder

After deploy, edit a Record Page (`VoiceCall` or `ConversationTranscript`) or an App Page, drag in **Topic Adherence Scorecard**, and fill these properties:

| Property                      | Example                                | Notes                                                 |
|-------------------------------|----------------------------------------|-------------------------------------------------------|
| Card Title                    | `Topic Adherence Scorecard`            | Header text                                           |
| Transcript Text               | `{!Record.TranscriptContent}`          | Field reference on Record Pages                       |
| Prompt Template API Name      | `Score_Agentforce_Adherence`           | DeveloperName of your Prompt Template                 |
| Agent (BotDefinition) API Name| `Service_Agent`                        | DeveloperName of the agent being evaluated            |
| Evaluator Flow API Name       | `Evaluate_Topic_Adherence`             | Default; matches the Flow you built                   |
| Auto-evaluate on load         | ☐ Off                                  | Off by default — LLM calls cost money                 |

---

## How the UI behaves

- **No data yet** → empty-state illustration with the `Evaluate` button; if any input is missing, the button is disabled and the message names exactly what's missing.
- **Evaluating** → small inline spinner with status text.
- **Loaded** → score badge in the header, three summary tiles, scoped tabset of the four categories. Each item row shows status icon, name, score badge, and a chevron; clicking expands the reasoning + evidence quote.
- **Error** → red alert with the unwrapped Apex message; the empty-state remains so the user can retry.

The component is dark-mode ready. Every color is sourced from SLDS 2 global styling hooks (`--slds-g-color-*`) — no hardcoded hex values.

---

## Accessibility notes

- Overall score region uses `aria-live="polite"` so screen readers announce updates.
- The body container exposes `aria-busy` during evaluation.
- Expandable rows are real `<button>` elements with `aria-expanded`. Keyboard activation via Enter/Space works out of the box.
- Status icons have `alternative-text` matching the status label.
- High-contrast and `prefers-reduced-motion` media queries are honored.

---

## Extending

## Assign coaching actions (Alert__c)

Each expanded row in the scorecard has an **Assign action** button. Clicking it opens a modal that creates an `Alert__c` record assigned to another user, with the scorecard finding pre-filled.

### What gets pre-populated

| Field                | Source                                                 |
|----------------------|--------------------------------------------------------|
| `Subject__c`         | `Coaching follow-up: <item name>`                      |
| `Description__c`     | Item name, status, score, reasoning, transcript evidence |
| `Priority__c`        | `failed` → High · `partial` → Medium · `passed` → Low  |
| `Status__c`          | `New`                                                  |
| `Score_Item_Id__c`   | `item.id` from the scorecard JSON (hidden field)       |
| `Score_Category__c`  | Tab the item came from: `Topics`/`Instructions`/`Actions`/`Criteria` |
| `Related_Record_Id__c` | The component's `recordId` (e.g. the VoiceCall Id)   |
| `OwnerId`            | **The user picks this** — required, no pre-fill        |

The user can override any visible field before saving. The hidden traceability fields silently stamp every Alert so reports can roll them back up to a specific scorecard run.

### `Alert__c` schema (included in this bundle)

The custom object and all fields are in `force-app/main/default/objects/Alert__c/`. Deploying the bundle creates:

| Field API name           | Type                | Notes                                                              |
|--------------------------|---------------------|--------------------------------------------------------------------|
| `Name`                   | Auto-Number `AL-{0000}` | Standard name field                                              |
| `Subject__c`             | Text(255), required |                                                                    |
| `Description__c`         | Long Text Area      |                                                                    |
| `Priority__c`            | Picklist            | Low / **Medium** / High (restricted)                               |
| `Status__c`              | Picklist            | **New** / In Progress / Completed / Cancelled (restricted)         |
| `Score_Item_Id__c`       | Text(64)            | External ID — links back to the scorecard item                     |
| `Score_Category__c`      | Picklist            | Topics / Instructions / Actions / Criteria (restricted)            |
| `Related_Record_Id__c`   | Text(18)            | External ID — VoiceCall / ConversationTranscript / etc.            |

`OwnerId` is the standard owner field — that's the assigned user.

> The bundle ships **without** a permission set. Grant your users CRUD on `Alert__c` and Read/Edit on the fields above before testing. The `lightning-record-edit-form` enforces FLS — if a field is hidden by FLS the form won't render it, and required fields will surface a clear error.

### Events the scorecard fires

| Event              | Detail                                                       | When                        |
|--------------------|--------------------------------------------------------------|-----------------------------|
| `scorecardloaded`  | `{ scorecard }`                                              | After successful evaluation |
| `alertcreated`     | `{ alertId, scoreItemId, categoryKey }`                      | After an Alert is assigned  |

Listen for `alertcreated` from a parent component if you want to refresh a related list, increment a counter, or run any post-assignment workflow.

### Customizing the modal

The modal is a separate sub-component (`c/assignActionModal`) using `lightning/modal`. To change the field set or the priority-mapping rule, edit `lwc/assignActionModal/assignActionModal.html` and `.js`. The form uses `lightning-record-edit-form` with hardcoded field API names that match the included metadata — if you rename any field on `Alert__c`, update those references too.

### Follow-up Task creation (record-triggered Flow)

When an `Alert__c` is inserted, the bundled **`Create_Task_From_Alert`** Flow fires and creates a `Task` for the same assignee. The Task appears in two places automatically: the user's **My Tasks** list views, and the **Activity timeline** on the Alert detail page (via `Task.WhatId = Alert.Id`).

**Why a Flow and not Apex?** The LWC bundle stays code-free for this workflow. Admins can extend the Flow (add email alerts, route to queues, conditional logic per category) without a deploy or test class updates.

**Task field mapping:**

| Task field      | Source                                                        |
|-----------------|---------------------------------------------------------------|
| `OwnerId`       | `Alert__c.OwnerId` — the assignee                             |
| `Subject`       | `Alert__c.Subject__c` (truncated to 255 chars)                |
| `Description`   | `Alert__c.Description__c` (already contains reasoning + evidence) |
| `Priority`      | `Alert__c.Priority__c` — High/Medium/Low values align with the stock Task picklist |
| `Status`        | `Not Started`                                                  |
| `WhatId`        | `Alert__c.Id` — relates the Task to the Alert                  |
| `ActivityDate`  | Priority-driven: **High = TODAY + 2**, **Medium = TODAY + 5**, **Low = TODAY + 10** |

**Atomicity note:** record-triggered Flows on `RecordAfterSave` execute in the same transaction as the Alert insert. If the Task creation fails (e.g. validation rule on Task), the entire transaction rolls back and the Alert is **not** created — the user sees the validation error in the modal. This gives you Apex-style atomicity without the Apex.

**Extending the Flow:**
- **Email the assignee** — add a Send Email action after `Create_Followup_Task` referencing `$Record.OwnerId`.
- **Route by category** — add a decision on `$Record.Score_Category__c` and assign different owners or due dates per category (e.g. Actions → Compliance team, Topics → coaching queue).
- **Skip Tasks for low-priority** — add an entry condition `$Record.Priority__c != 'Low'` on the Start element.
- **Different Task subject** — edit the `Formula_Task_Subject` formula in the Flow.

**Prerequisite already met:** `Alert__c` is deployed with `<enableActivities>true</enableActivities>`, which is what allows `Task.WhatId` to reference an Alert record.

## Extending