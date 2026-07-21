/**
 * Assign Action Modal
 *
 * Opened programmatically by topicAdherenceScorecard:
 *
 *   import AssignActionModal from 'c/assignActionModal';
 *   const result = await AssignActionModal.open({
 *       size: 'small',
 *       scoreItem: itemBeingAssigned,
 *       relatedRecordId: this.recordId
 *   });
 *
 * Returns:
 *   { status: 'success',   recordId: '<new Alert__c id>' }
 *   { status: 'cancelled' }
 *
 * The form uses `lightning-record-edit-form` so Field-Level Security is
 * enforced automatically. No Apex is required — the LDS create call
 * goes through standard platform plumbing.
 */
import { api } from 'lwc';
import LightningModal from 'lightning/modal';

const PRIORITY_BY_STATUS = {
    failed:  'High',
    partial: 'Medium',
    passed:  'Low'
};

export default class AssignActionModal extends LightningModal {
    /** The scored item being assigned (with categoryKey added by the parent). */
    @api scoreItem;

    /** Optional VoiceCall / ConversationTranscript Id to stamp on the Alert. */
    @api relatedRecordId;

    isSubmitting = false;
    error;

    // ───────────────────────────────────────────────────────────────────
    // Computed pre-fill values
    // ───────────────────────────────────────────────────────────────────

    get prefillSubject() {
        if (!this.scoreItem) return '';
        return `Suggested Improvement: ${this.scoreItem.name}`.slice(0, 255);
    }

    get prefillDescription() {
        if (!this.scoreItem) return '';

        // Hard cap from the org's Summary__c field length.
        const MAX_LEN = 1000;
        // Reserved characters for the section headers, paragraph tags,
        // and the trailer line. Body content is shared across 3 sections.
        const SECTION_OVERHEAD = 220;
        const perSection = Math.floor((MAX_LEN - SECTION_OVERHEAD) / 3);

        const improvement = this._truncate(this._buildImprovementText(), perSection);
        const reasoning   = this._truncate(this.scoreItem.reasoning || '', perSection);
        const evidence    = this._truncate(this.scoreItem.evidence  || '', perSection);

        // Build HTML sections so rich text Summary__c renders them with
        // visible line breaks and bold headers instead of one wall of text.
        const sections = [];
        sections.push(
            `<p><b>1. Suggested improvement</b><br>${this._escape(improvement)}</p>`
        );
        if (reasoning) {
            sections.push(
                `<p><b>2. Why this came up</b><br>${this._escape(reasoning)}</p>`
            );
        }
        if (evidence) {
            sections.push(
                `<p><b>3. Transcript evidence</b><br>${this._escape(evidence)}</p>`
            );
        }

        // Trailer for traceability.
        const statusLabel = this.scoreItem.statusLabel || this.scoreItem.status || '';
        const score = this.scoreItem.score != null ? `score ${this.scoreItem.score}` : '';
        const trailer = [statusLabel, score].filter(s => s).join(' · ');
        sections.push(
            `<p><i>Auto-generated from scorecard finding "${this._escape(this.scoreItem.name)}"` +
            (trailer ? ` (${this._escape(trailer)})` : '') +
            `</i></p>`
        );

        // Final safety net: hard-truncate if the HTML overhead pushed us over.
        let html = sections.join('');
        if (html.length > MAX_LEN) {
            html = html.slice(0, MAX_LEN - 7) + '…</p>';
        }
        return html;
    }

    _truncate(text, max) {
        if (!text) return '';
        const t = text.trim();
        if (t.length <= max) return t;
        return t.slice(0, max - 1) + '…';
    }

    _escape(text) {
        if (!text) return '';
        return String(text)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    /**
     * Use the LLM-supplied suggestedImprovement when present.
     * Fall back to a sensible default derived from status + reasoning so
     * the field is never empty even on older scorecard runs.
     */
    _buildImprovementText() {
        const llm = this.scoreItem.suggestedImprovement;
        if (llm && llm.trim().length) return llm.trim();

        const status = (this.scoreItem.status || '').toLowerCase();
        const name = this.scoreItem.name || 'this item';
        const reasoning = this.scoreItem.reasoning || '';

        if (status === 'failed') {
            return `Coach the agent on "${name}". ${reasoning}`.trim();
        }
        if (status === 'partial') {
            return `Reinforce expected behavior for "${name}". ${reasoning}`.trim();
        }
        return `Acknowledge strong performance on "${name}" and reinforce the behavior.`;
    }

    get prefillPriority() {
        return PRIORITY_BY_STATUS[this.scoreItem?.status] || 'Medium';
    }

    get prefillScoreItemId() {
        return this.scoreItem?.id || '';
    }

    get prefillCategory() {
        const key = this.scoreItem?.categoryKey;
        if (!key) return null;
        return key.charAt(0).toUpperCase() + key.slice(1); // 'topics' -> 'Topics'
    }

    get hasScoreContext() {
        return !!this.scoreItem;
    }

    get hasRelatedRecord() {
        return !!this.relatedRecordId;
    }

    // ───────────────────────────────────────────────────────────────────
    // Form lifecycle
    // ───────────────────────────────────────────────────────────────────

    handleSave() {
        // Trigger the form's submit; handleSubmit() below intercepts.
        const form = this.template.querySelector('lightning-record-edit-form');
        if (form) form.submit();
    }

    handleSubmit(event) {
        // Prevent default so we can flag the submitting state cleanly.
        // The form will still proceed to handleSuccess / handleError.
        this.isSubmitting = true;
        this.error = undefined;
        // Let the form keep handling — don't preventDefault.
        return event;
    }

    handleSuccess(event) {
        this.isSubmitting = false;
        this.close({ status: 'success', recordId: event.detail.id });
    }

    handleError(event) {
        this.isSubmitting = false;
        const detail = event.detail || {};
        this.error =
            detail.message ||
            (Array.isArray(detail.output?.errors) && detail.output.errors[0]?.message) ||
            'Could not create the Alert. Check field-level security and required fields.';
    }

    handleCancel() {
        this.close({ status: 'cancelled' });
    }
}
