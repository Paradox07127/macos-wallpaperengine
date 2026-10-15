'use strict';
const auditNonce = "ss-b3ed47df60a84112";
const auditRole = "sound-a-mintime";
let localSeq = 0;
let localFrame = 0;
let initObserved = false;
let firstUpdateObserved = false;
function emitPhase(phase) {
    console.error('AUDIT_SS_01A13310 ' + JSON.stringify({
        schema:'lw.wpe.s11.cold-order.marker.v2', nonce:auditNonce,
        caseId:'cold-general-object', role:auditRole, phase:phase,
        localSeq:++localSeq, frame:localFrame
    }));
}
emitPhase('module-global');
export function init(value) {
    if (!initObserved) {
        initObserved = true;
        emitPhase('init');
    }
}
export function update(value) {
    ++localFrame;
    if (!firstUpdateObserved) {
        firstUpdateObserved = true;
        emitPhase('first-update');
    }
}
