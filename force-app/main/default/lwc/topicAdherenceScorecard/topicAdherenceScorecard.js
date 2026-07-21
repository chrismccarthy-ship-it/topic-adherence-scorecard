/**
 * Topic Adherence Scorecard
 *
 * Evaluates an Agentforce voice-call transcript against:
 *   1. The criteria defined in a Salesforce Prompt Template
 *   2. The target agent's topics, instructions, and actions
 *
 * Architecture:
 *   LWC ──imperative──▶ Apex ──Flow.Interview──▶ Flow (Prompt Template action)
 *                                                     │
 *                                                     ▼
 *                                              Models API → LLM
 *
 * From any scored item the reviewer can open the Assign Action modal to
 * create an Alert__c record assigned to another user, with the item's
 * subject, reasoning, evidence, and recommended priority pre-populated.
 */
import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import evaluateAdherence from '@salesforce/apex/TopicAdherenceScorecardController.evaluateAdherence';
import AssignActionModal from 'c/assignActionModal';

const CATEGORY_ORDER = ['topics', 'instructions', 'actions', 'criteria'];

const STATUS_META = {
    passed:  { variant: 'success', icon: 'utility:success',  label: 'Passed'  },
    partial: { variant: 'warning', icon: 'utility:warning',  label: 'Partial' },
    failed:  { variant: 'error',   icon: 'utility:error',    label: 'Failed'  }
};

export default class TopicAdherenceScorecard extends LightningElement {
    @api recordId;
    @api transcript;
    @api promptTemplateApiName;
    @api agentApiName;
    @api evaluatorFlowApiName = 'Evaluate_Topic_Adherence';
    @api autoEvaluate = false;
    @api cardTitle = 'Topic Adherence Scorecard';

    @track scorecard;
    isLoading = false;
    error;
    expandedIds = new Set();
    activeTab = 'topics';

    connectedCallback() {
        if (this.autoEvaluate && this.canEvaluate) {
            this.runEvaluation();
        }
    }

    // ═══ GETTERS ═══════════════════════════════════════════════════════

    get canEvaluate() {
        return !!(this.transcript && this.promptTemplateApiName && this.agentApiName);
    }

    get hasData() {
        return !!(this.scorecard && Array.isArray(this.scorecard.categories) && this.scorecard.categories.length);
    }

    /** Show the empty/pre-evaluation illustration when nothing's loaded and nothing's in flight. */
    get showEmptyState() {
        return !this.hasData && !this.isLoading && !this.error;
    }

    get evaluateDisabled() {
        return this.isLoading || !this.canEvaluate;
    }

    get evaluateLabel() {
        return this.hasData ? 'Re-evaluate' : 'Evaluate';
    }

    get missingInputsMessage() {
        const missing = [];
        if (!this.transcript) missing.push('transcript');
        if (!this.promptTemplateApiName) missing.push('prompt template');
        if (!this.agentApiName) missing.push('agent');
        return missing.length
            ? `Provide a ${missing.join(', ')} to enable evaluation.`
            : '';
    }

    get overallScoreText() {
        if (!this.hasData || this.scorecard.overallScore == null) return '—';
        return `${Math.round(this.scorecard.overallScore)}%`;
    }

    get overallVariant() {
        if (!this.hasData || this.scorecard.overallScore == null) return 'inverse';
        const s = this.scorecard.overallScore;
        if (s >= 85) return 'success';
        if (s >= 60) return 'warning';
        return 'error';
    }

    get overallBadgeClass() {
        return `slds-badge slds-badge_lightest score-badge score-badge_${this.overallVariant}`;
    }

    get summaryTiles() {
        if (!this.hasData) return [];
        return [
            { key: 'passed',  label: 'Passed',  count: this.scorecard.passedCount  ?? 0, variant: 'success' },
            { key: 'partial', label: 'Partial', count: this.scorecard.partialCount ?? 0, variant: 'warning' },
            { key: 'failed',  label: 'Failed',  count: this.scorecard.failedCount  ?? 0, variant: 'error'   }
        ].map(tile => ({
            ...tile,
            tileClass: `score-tile score-tile_${tile.variant}`,
            iconName:  STATUS_META[tile.key].icon
        }));
    }

    get displayCategories() {
        if (!this.hasData) return [];
        return [...this.scorecard.categories]
            .sort((a, b) => CATEGORY_ORDER.indexOf(a.key) - CATEGORY_ORDER.indexOf(b.key))
            .map(cat => ({
                key: cat.key,
                label: cat.label,
                value: cat.key,
                iconName: cat.iconName || this._categoryIcon(cat.key),
                scoreText: cat.score != null ? `${Math.round(cat.score)}%` : '—',
                isEmpty: !cat.items || !cat.items.length,
                items: (cat.items || []).map(item => this._decorateItem(item, cat.key))
            }));
    }

    get evaluatedAtText() {
        if (!this.hasData || !this.scorecard.evaluatedAt) return '';
        return `Evaluated ${this.scorecard.evaluatedAt}`;
    }

    get modelText() {
        if (!this.hasData || !this.scorecard.modelUsed) return '';
        return ` · ${this.scorecard.modelUsed}`;
    }

    // ═══ EVENT HANDLERS ════════════════════════════════════════════════

    handleEvaluate() {
        this.runEvaluation();
    }

    handleTabActive(event) {
        this.activeTab = event.target.value;
    }

    handleToggleItem(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        const next = new Set(this.expandedIds);
        if (next.has(id)) next.delete(id);
        else next.add(id);
        this.expandedIds = next;
    }

    /**
     * Opens the Assign Action modal for a specific scored item.
     * Stops propagation so the parent row's expand/collapse doesn't fire.
     */
    async handleAssignAction(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        const item = this._findItem(id);
        if (!item) return;

        try {
            const result = await AssignActionModal.open({
                size: 'small',
                scoreItem: item,
                relatedRecordId: this.recordId
            });

            if (result && result.status === 'success') {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Alert assigned',
                    message: `Coaching action created for "${item.name}".`,
                    variant: 'success'
                }));
                this.dispatchEvent(new CustomEvent('alertcreated', {
                    detail: {
                        alertId: result.recordId,
                        scoreItemId: id,
                        categoryKey: item.categoryKey
                    }
                }));
            }
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not assign action',
                message: this._reduceError(e),
                variant: 'error'
            }));
        }
    }

    // ═══ CORE LOGIC ════════════════════════════════════════════════════

    async runEvaluation() {
        if (!this.canEvaluate) {
            this.error = this.missingInputsMessage;
            return;
        }

        this.isLoading = true;
        this.error = undefined;

        try {
            const result = await evaluateAdherence({
                recordId: this.recordId,
                transcript: this.transcript,
                promptTemplateApiName: this.promptTemplateApiName,
                agentApiName: this.agentApiName,
                flowApiName: this.evaluatorFlowApiName
            });

            this.scorecard = JSON.parse(JSON.stringify(result));
            this.expandedIds = new Set();

            this.dispatchEvent(new CustomEvent('scorecardloaded', {
                detail: { scorecard: this.scorecard }
            }));
        } catch (e) {
            this.error = this._reduceError(e);
            this.scorecard = undefined;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Evaluation failed',
                message: this.error,
                variant: 'error'
            }));
        } finally {
            this.isLoading = false;
        }
    }

    // ═══ INTERNAL HELPERS ══════════════════════════════════════════════

    _decorateItem(item, categoryKey) {
        const meta = STATUS_META[item.status] || STATUS_META.failed;
        const expanded = this.expandedIds.has(item.id);
        return {
            ...item,
            categoryKey,
            statusLabel: meta.label,
            statusIcon: meta.icon,
            statusVariant: meta.variant,
            rowClass: `score-row score-row_${meta.variant}${expanded ? ' score-row_expanded' : ''}`,
            scoreText: item.score != null ? `${Math.round(item.score)}` : '—',
            expanded,
            ariaExpanded: String(expanded),
            toggleIcon: expanded ? 'utility:chevrondown' : 'utility:chevronright',
            toggleLabel: expanded ? `Collapse ${item.name}` : `Expand ${item.name}`,
            hasEvidence: !!(item.evidence && item.evidence.trim().length),
            hasReasoning: !!(item.reasoning && item.reasoning.trim().length)
        };
    }

    _findItem(id) {
        if (!this.hasData) return null;
        for (const cat of this.scorecard.categories) {
            if (!cat.items) continue;
            const found = cat.items.find(i => i.id === id);
            if (found) {
                const meta = STATUS_META[found.status] || STATUS_META.failed;
                return {
                    ...found,
                    categoryKey: cat.key,
                    categoryLabel: cat.label,
                    statusLabel: meta.label
                };
            }
        }
        return null;
    }

    _categoryIcon(key) {
        switch (key) {
            case 'topics':       return 'utility:topic2';
            case 'instructions': return 'utility:list';
            case 'actions':      return 'utility:flow';
            case 'criteria':     return 'utility:check';
            default:             return 'utility:rules';
        }
    }

    _reduceError(err) {
        if (!err) return 'Unknown error';
        if (typeof err === 'string') return err;
        if (Array.isArray(err.body)) return err.body.map(e => e.message).join(', ');
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return JSON.stringify(err);
    }
}
