# Topic Adherence Scorecard

Automated QA for **Agentforce voice interactions**. A Lightning Web Component that scores a call transcript against:

1. The evaluation rubric defined in a **Salesforce Prompt Template**
2. The target **Agentforce agent's topics, instructions, and actions** (from `BotDefinition` + `GenAiPluginDefinition` + `GenAiFunctionDef`, where present)

Reviewers see an overall score, pass/partial/fail tiles, and a four-tab breakdown — **Topics · Instructions · Actions · Evaluation Criteria** — where each item is expandable to reveal the LLM's reasoning and the transcript evidence supporting the verdict. From any finding, a reviewer can open a modal that creates an `Alert__c` record assigned to another user, pre-populated with an AI-generated Suggested Improvement. A record-triggered Flow then creates a follow-up Task on the assignee's list view.

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

## What's in the bundle

```
force-app/main/default/
├── classes/
│   ├── TopicAdherenceScorecardController.cls       ← imperative controller + JSON sanitizer
│   ├── TopicAdherenceScorecardControllerTest.cls   ← Apex tests
│   └── *.cls-meta.xml
├── flows/
│   └── Create_Task_From_Alert.flow-meta.xml        ← record-triggered Task creation
├── lwc/
│   ├── topicAdherenceScorecard/                    ← main component (score card, tabs, rows)
│   └── assignActionModal/                          ← modal for creating Alert records
└── objects/
    └── Alert__c/                                    ← coaching action record
        ├── Alert__c.object-meta.xml
        └── fields/
            ├── Subject__c.field-meta.xml
            ├── Description__c.field-meta.xml
            ├── Summary__c.field-meta.xml           ← rich text, where AI content lands
            ├── Priority__c.field-meta.xml
            ├── Status__c.field-meta.xml
            ├── Alert_Type__c.field-meta.xml        ← "AI Insight" for scorecard-created alerts
            ├── Score_Item_Id__c.field-meta.xml     ← traceability
            ├── Score_Category__c.field-meta.xml    ← traceability
            └── Related_Record_Id__c.field-meta.xml ← traceability
```

---

## Prerequisites

1. **Agentforce agent** (`BotDefinition`) with topics and actions configured — the Apex controller queries this via dynamic Schema describe, so it degrades gracefully if the Agentforce metadata objects aren't yet available in your org
2. **Prompt Template** containing the scoring rubric. Accepts two inputs:
   - `transcript` (Text) — the call transcript
   - `agentConfig` (Text) — serialized JSON of the agent's topics/instructions/actions
   
   Must instruct the LLM to return JSON matching the [scorecard schema](#scorecard-json-schema) below.
3. **Autolaunched Flow** (default name `Evaluate_Topic_Adherence`) — see [Flow contract](#flow-contract) below.

---

## Deployment

```powershell
# 1. cd to the project root (must contain sfdx-project.json)
cd C:\path\to\topic-adherence-scorecard

# 2. Deploy everything
sf project deploy start --source-dir force-app --target-org YOUR_ALIAS

# 3. Run tests
sf apex run test --class-names TopicAdherenceScorecardControllerTest \
   --code-coverage --result-format human --wait 10 --target-org YOUR_ALIAS
```

If you only need to redeploy the main LWC after edits:

```powershell
sf project deploy start --metadata LightningComponentBundle:topicAdherenceScorecard --target-org YOUR_ALIAS
```

**FLS on `Alert__c`** — the bundle ships without a permission set. After deploy, grant your users Read/Edit on all `Alert__c` custom fields (Setup → Profiles → System Administrator → Object Settings → Alert), or wrap the fields in a permission set of your own.

---

## Configuration in App Builder

After deploy, edit any Record Page or App Page, drag in **Topic Adherence Scorecard**, and fill these properties:

| Property                       | Example                       | Notes                                                                                     |
| ------------------------------ | ----------------------------- | ----------------------------------------------------------------------------------------- |
| Card Title                     | `Topic Adherence Scorecard`   | Header text                                                                               |
| Transcript Text                | `{!Record.TranscriptContent}` | Field reference on Record Pages, or paste a literal string for demo purposes              |
| Prompt Template API Name       | `Score_Agentforce_Adherence`  | DeveloperName of your Prompt Template                                                     |
| Agent (BotDefinition) API Name | `Service_Agent`               | DeveloperName of the agent being evaluated                                                |
| Evaluator Flow API Name        | `Evaluate_Topic_Adherence`    | Default; must match your Flow's API name                                                  |
| Auto-evaluate on load          | ☐ Off                         | Off by default — LLM calls cost money and shouldn't fire on every page load               |

---

## Flow contract

The Apex controller calls the Flow synchronously. Build the Flow once in Flow Builder.

**Input variables (the Apex controller populates these):**

| Variable                | Type | Description                                     |
| ----------------------- | ---- | ----------------------------------------------- |
| `recordId`              | Text | Optional context record (e.g. VoiceCall.Id)     |
| `transcript`            | Text | Raw transcript text                             |
| `agentConfigJson`       | Text | Serialized JSON of the agent's topics + actions |
| `promptTemplateApiName` | Text | DeveloperName of the Prompt Template to invoke  |

**Output variable (the Apex controller reads this):**

| Variable        | Type | Description                                                         |
| --------------- | ---- | ------------------------------------------------------------------- |
| `scorecardJson` | Text | JSON string matching the [scorecard schema](#scorecard-json-schema) |

**Inside the Flow:** drop in the **Prompt Template** invocable action, pass it `transcript` and `agentConfigJson` as inputs, store the LLM's response in `scorecardJson`.

---

## Scorecard JSON schema

The Prompt Template must instruct the LLM to emit JSON in this shape:

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
          "evidence": "Agent: I can help with that billing question...",
          "suggestedImprovement": "Reinforce this pattern in coaching — the agent's fast topic identification kept AHT down."
        }
      ]
    },
    { "key": "instructions", "label": "Instructions", "score": 80, "items": [ /* ... */ ] },
    { "key": "actions",      "label": "Actions",      "score": 75, "items": [ /* ... */ ] },
    { "key": "criteria",     "label": "Evaluation Criteria", "score": 88, "items": [ /* ... */ ] }
  ]
}
```

- `status` ∈ `"passed" | "partial" | "failed"` — the LWC color-codes accordingly
- `score` is 0–100 — rendered as a badge
- `suggestedImprovement` is optional per item; the LWC falls back to a templated string if omitted
- `passedCount`, `partialCount`, `failedCount`, and `evaluatedAt` are computed **by Apex** — the LLM doesn't emit them

The Apex controller sanitizes common LLM JSON glitches before parsing: markdown code fences, smart quotes, `\"\"` collapse, preamble text before the first `{`, and trailing commas.

---

## Assign coaching actions (Alert__c)

Each expanded row has an **Assign action** button. Clicking it opens a modal titled **"Assign suggested improvement"** that creates an `Alert__c` record assigned to another user.

### What gets pre-populated

| Alert field            | Source                                                          |
| ---------------------- | --------------------------------------------------------------- |
| `Subject__c`           | `Suggested Improvement: <finding name>` (truncated to 255)      |
| `Summary__c`           | Numbered rich-text sections: **1. Suggested improvement**, **2. Why this came up**, **3. Transcript evidence**, plus a trailer with finding metadata |
| `Status__c`            | `New`                                                           |
| `Alert_Type__c`        | `AI Insight` (hidden field, not shown in the form)              |
| `Score_Item_Id__c`     | `item.id` from the scorecard JSON (hidden, traceability)        |
| `Score_Category__c`    | Tab the item came from (hidden, traceability)                   |
| `Related_Record_Id__c` | The component's `recordId` (hidden, traceability)               |
| `OwnerId`              | **The user picks this** — required, no pre-fill                 |

The Summary field is capped client-side at ~1000 characters and split evenly across the three numbered sections, with the LLM's `suggestedImprovement` taking priority.

### Alert__c schema included in this bundle

| Field API name         | Type                    | Notes                                                                       |
| ---------------------- | ----------------------- | --------------------------------------------------------------------------- |
| `Name`                 | Auto-Number `AL-{0000}` | Standard name field                                                         |
| `Subject__c`           | Text(255), required     | Written by the modal                                                        |
| `Summary__c`           | Rich Text Area (32,768) | Written by the modal — HTML-formatted, numbered sections                    |
| `Alert_Type__c`        | Picklist                | AI Insight (default) / Manual / System — restricted                         |
| `Description__c`       | Long Text Area (32,768) | Legacy plain-text description (kept for backwards compat, not written by modal) |
| `Priority__c`          | Picklist                | Low / **Medium** / High — restricted, not written by the current modal      |
| `Status__c`            | Picklist                | **New** / In Progress / Completed / Cancelled — restricted                  |
| `Score_Item_Id__c`     | Text(64)                | External ID — links back to the scorecard item                              |
| `Score_Category__c`    | Picklist                | Topics / Instructions / Actions / Criteria — restricted                     |
| `Related_Record_Id__c` | Text(18)                | External ID — VoiceCall / ConversationTranscript, etc.                      |

`OwnerId` is the standard owner field — that's the assigned user.

### Follow-up Task creation (record-triggered Flow)

When an `Alert__c` is inserted, the bundled **`Create_Task_From_Alert`** Flow fires and creates a `Task` for the same assignee. The Task appears in two places automatically: the user's **My Tasks** list views, and the **Activity timeline** on the Alert detail page (via `Task.WhatId = Alert.Id`).

**Why a Flow and not Apex?** Admins can extend the Flow (email alerts, queue routing, category-specific due dates) without a code deploy.

**Task field mapping:**

| Task field     | Source                                                                              |
| -------------- | ----------------------------------------------------------------------------------- |
| `OwnerId`      | `Alert__c.OwnerId` — the assignee                                                   |
| `Subject`      | `Alert__c.Subject__c` (truncated to 255)                                            |
| `Description`  | `Alert__c.Description__c`                                                           |
| `Priority`     | `Alert__c.Priority__c` — High/Medium/Low aligns with the stock Task picklist        |
| `Status`       | `Not Started`                                                                       |
| `WhatId`       | `Alert__c.Id` — relates the Task to the Alert                                       |
| `ActivityDate` | Priority-driven: **High = TODAY + 2**, **Medium = TODAY + 5**, **Low = TODAY + 10** |

**Atomicity:** the Flow runs `RecordAfterSave` in the same transaction as the Alert insert. If the Task creation fails (e.g. validation rule), the entire transaction rolls back and the Alert isn't created either — the user sees the validation error in the modal.

### Events the scorecard dispatches

| Event             | Detail                                  | When                        |
| ----------------- | --------------------------------------- | --------------------------- |
| `scorecardloaded` | `{ scorecard }`                         | After successful evaluation |
| `alertcreated`    | `{ alertId, scoreItemId, categoryKey }` | After an Alert is assigned  |

Listen for `alertcreated` from a parent component if you want to refresh a related list or trigger post-assignment workflow.

### Customizing the modal

The modal is a separate sub-component (`c/assignActionModal`) using `lightning/modal`. To change the field set, edit `lwc/assignActionModal/assignActionModal.html`. The form uses `lightning-record-edit-form`, so FLS is enforced automatically — fields hidden by FLS won't render.

---

## How the UI behaves

- **No data yet** → empty-state illustration with the `Evaluate` button; if any input is missing, the button is disabled and the message names exactly what's missing
- **Evaluating** → small inline spinner with status text
- **Loaded** → score badge in the header, three summary tiles (passed / partial / failed), scoped tabset of the four categories. Each row shows a status icon, name, score badge, and a chevron; clicking expands the reasoning + evidence quote + Assign action button
- **Error** → red alert with the unwrapped Apex message; the empty-state remains so the user can retry

The component honors SLDS 2 global styling hooks (`--slds-g-color-*`) — no hardcoded hex values.

---

## Accessibility

- Overall score region uses `aria-live="polite"` so screen readers announce updates
- The body container exposes `aria-busy` during evaluation
- Expandable rows are real `<button>` elements with `aria-expanded` — keyboard activation via Enter/Space works out of the box
- Status icons have `alternative-text` matching the status label
- `prefers-reduced-motion` and high-contrast media queries are honored

---

## Extending

- **Different transcript source** — replace the `@api transcript` binding in App Builder with a field reference, or have a parent LWC set the property programmatically
- **More categories** — add them to the prompt template's JSON output; the LWC renders any `key` in `displayCategories` automatically. Known keys (`topics | instructions | actions | criteria`) get default icons; anything else gets `utility:rules`
- **Persist scorecard runs** — listen for the `scorecardloaded` event and write the payload to a custom object
- **Different Alert workflow** — the modal fires an `alertcreated` event with the new Alert Id; wire that into your own automation
- **Change the Task due-date policy** — edit the three formula elements in the `Create_Task_From_Alert` Flow (High/Medium/Low offsets)
