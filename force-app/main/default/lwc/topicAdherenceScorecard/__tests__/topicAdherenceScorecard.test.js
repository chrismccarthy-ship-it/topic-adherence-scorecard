import { createElement } from 'lwc';
import TopicAdherenceScorecard from 'c/topicAdherenceScorecard';
import evaluateAdherence from '@salesforce/apex/TopicAdherenceScorecardController.evaluateAdherence';
import AssignActionModal from 'c/assignActionModal';

// Mock the Apex method.
jest.mock(
    '@salesforce/apex/TopicAdherenceScorecardController.evaluateAdherence',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

// Mock the modal sub-component — we only care about open() being called.
jest.mock(
    'c/assignActionModal',
    () => ({ default: { open: jest.fn() } }),
    { virtual: true }
);

const MOCK_SCORECARD = {
    overallScore: 87,
    summary: 'Agent stayed on topic but missed disclosure.',
    modelUsed: 'GPT-4 Omni',
    evaluatedAt: 'Nov 5, 2025 2:14 PM',
    passedCount: 2,
    partialCount: 1,
    failedCount: 1,
    categories: [
        {
            key: 'topics',
            label: 'Topics',
            score: 90,
            items: [
                {
                    id: 't1',
                    name: 'Billing inquiry handling',
                    description: 'Caller asked about charges.',
                    status: 'passed',
                    score: 95,
                    reasoning: 'Agent identified billing immediately.',
                    evidence: 'Agent: I can help with that billing question.'
                }
            ]
        },
        {
            key: 'actions',
            label: 'Actions',
            score: 0,
            items: [
                {
                    id: 'a1',
                    name: 'Disclose recording',
                    status: 'failed',
                    score: 0,
                    reasoning: 'No recording disclosure detected.',
                    evidence: ''
                }
            ]
        }
    ]
};

const flush = () => Promise.resolve();

const createComponent = (props = {}) => {
    const el = createElement('c-topic-adherence-scorecard', { is: TopicAdherenceScorecard });
    Object.assign(el, props);
    document.body.appendChild(el);
    return el;
};

const loadScorecard = async (el) => {
    evaluateAdherence.mockResolvedValue(MOCK_SCORECARD);
    el.transcript = 'hello';
    el.promptTemplateApiName = 'Tpl';
    el.agentApiName = 'Agt';
    await flush();
    el.shadowRoot.querySelector('lightning-button').click();
    await flush();
    await flush();
    await flush();
};

describe('c-topic-adherence-scorecard', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    // ─────────────────────────────────────────────────────────────────────
    // Empty state
    // ─────────────────────────────────────────────────────────────────────

    it('renders empty state when inputs are blank', async () => {
        const el = createComponent();
        await flush();
        expect(el.shadowRoot.textContent).toMatch(/No evaluation yet/);
    });

    // ─────────────────────────────────────────────────────────────────────
    // Evaluation
    // ─────────────────────────────────────────────────────────────────────

    it('renders the scorecard after successful evaluation', async () => {
        const el = createComponent();
        await loadScorecard(el);

        const badge = el.shadowRoot.querySelector('.score-badge');
        expect(badge.textContent).toMatch(/87%/);

        const tiles = el.shadowRoot.querySelectorAll('.score-tile');
        expect(tiles.length).toBe(3);
    });

    it('passes all required props to the Apex method', async () => {
        const el = createComponent({
            recordId: '0LQxx0000004CmA',
            transcript: 'hello',
            promptTemplateApiName: 'Tpl',
            agentApiName: 'Agt',
            evaluatorFlowApiName: 'My_Flow'
        });
        evaluateAdherence.mockResolvedValue(MOCK_SCORECARD);
        await flush();
        el.shadowRoot.querySelector('lightning-button').click();
        await flush();

        expect(evaluateAdherence).toHaveBeenCalledWith({
            recordId: '0LQxx0000004CmA',
            transcript: 'hello',
            promptTemplateApiName: 'Tpl',
            agentApiName: 'Agt',
            flowApiName: 'My_Flow'
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    // Expand / collapse
    // ─────────────────────────────────────────────────────────────────────

    it('toggles row expansion when header is clicked', async () => {
        const el = createComponent();
        await loadScorecard(el);

        const row = el.shadowRoot.querySelector('[data-id="t1"]');
        expect(row.getAttribute('aria-expanded')).toBe('false');

        row.click();
        await flush();

        expect(el.shadowRoot.querySelector('[data-id="t1"]').getAttribute('aria-expanded')).toBe('true');
        expect(el.shadowRoot.querySelector('.score-row__detail')).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────
    // Assign action modal — new functionality
    // ─────────────────────────────────────────────────────────────────────

    describe('assign action', () => {
        it('opens the modal with the correct score item when Assign clicked', async () => {
            AssignActionModal.open.mockResolvedValue({ status: 'cancelled' });

            const el = createComponent({ recordId: '0LQxx0000004CmA' });
            await loadScorecard(el);

            // Expand the row to reveal the Assign button.
            el.shadowRoot.querySelector('[data-id="t1"]').click();
            await flush();

            // Find the Assign button — lightning-button with data-id on the action row.
            const assignBtn = el.shadowRoot.querySelector(
                '.detail-actions lightning-button[data-id="t1"]'
            );
            expect(assignBtn).not.toBeNull();
            assignBtn.click();

            await flush();

            expect(AssignActionModal.open).toHaveBeenCalledTimes(1);
            const args = AssignActionModal.open.mock.calls[0][0];
            expect(args.size).toBe('small');
            expect(args.relatedRecordId).toBe('0LQxx0000004CmA');
            expect(args.scoreItem.id).toBe('t1');
            expect(args.scoreItem.name).toBe('Billing inquiry handling');
            expect(args.scoreItem.categoryKey).toBe('topics');
        });

        it('dispatches alertcreated event when modal returns success', async () => {
            AssignActionModal.open.mockResolvedValue({
                status: 'success',
                recordId: 'a01xx0000000001'
            });

            const el = createComponent();
            await loadScorecard(el);

            const handler = jest.fn();
            el.addEventListener('alertcreated', handler);

            el.shadowRoot.querySelector('[data-id="t1"]').click();
            await flush();
            el.shadowRoot.querySelector('.detail-actions lightning-button[data-id="t1"]').click();
            await flush();
            await flush();

            expect(handler).toHaveBeenCalled();
            const detail = handler.mock.calls[0][0].detail;
            expect(detail.alertId).toBe('a01xx0000000001');
            expect(detail.scoreItemId).toBe('t1');
            expect(detail.categoryKey).toBe('topics');
        });

        it('does NOT fire alertcreated when user cancels the modal', async () => {
            AssignActionModal.open.mockResolvedValue({ status: 'cancelled' });

            const el = createComponent();
            await loadScorecard(el);

            const handler = jest.fn();
            el.addEventListener('alertcreated', handler);

            el.shadowRoot.querySelector('[data-id="t1"]').click();
            await flush();
            el.shadowRoot.querySelector('.detail-actions lightning-button[data-id="t1"]').click();
            await flush();
            await flush();

            expect(handler).not.toHaveBeenCalled();
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    // Error handling
    // ─────────────────────────────────────────────────────────────────────

    it('shows error alert when Apex throws', async () => {
        evaluateAdherence.mockRejectedValue({ body: { message: 'LLM unavailable' } });
        const el = createComponent({
            transcript: 'hello',
            promptTemplateApiName: 'Tpl',
            agentApiName: 'Agt'
        });
        await flush();
        el.shadowRoot.querySelector('lightning-button').click();
        await flush();
        await flush();
        await flush();

        const alert = el.shadowRoot.querySelector('.slds-alert_error');
        expect(alert).not.toBeNull();
        expect(alert.textContent).toMatch(/LLM unavailable/);
    });
});
