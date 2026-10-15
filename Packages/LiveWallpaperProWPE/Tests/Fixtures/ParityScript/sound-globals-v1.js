'use strict';
const nonce = "ss-6ab1ae35e09f2589";
const caseId = 'sound-global-phase';
let seq = 0;
let frame = 0;
let initObserved = false;
let updateObserved = false;
function emit(event, detail) {
    console.error('AUDIT_SS_01A13310 ' + JSON.stringify({schema:'lw.wpe.s10.sound-globals.v1',
        nonce:nonce, caseId:caseId, role:'sound-volume', seq:++seq, frame:frame, event:event, detail:detail}));
}
function errorInfo(error) {
    return {type:typeof error, name:error && typeof error.name === 'string' ? error.name : null,
        message:error && typeof error.message === 'string' ? error.message : String(error),
        instanceofError:error instanceof Error};
}
function observe(event, operation) {
    try {
        const result = operation();
        const type = typeof result;
        emit(event, {outcome:'return', resultType:type, isUndefined:result === undefined,
            value:type === 'boolean' || type === 'string' || type === 'number' && isFinite(result) ? result : null});
    } catch (error) {
        emit(event, {outcome:'exception', error:errorInfo(error)});
    }
}
function snapshot(phase) {
    observe(phase + '.thisObject.volume', function () { return thisObject.volume; });
    observe(phase + '.thisLayer.volume', function () { return thisLayer.volume; });
    observe(phase + '.thisObject.isPlaying', function () { return thisObject.isPlaying(); });
    observe(phase + '.thisLayer.isPlaying', function () { return thisLayer.isPlaying(); });
}
emit('module-global', {thisObjectType:typeof thisObject, thisLayerType:typeof thisLayer});
observe('global.alias-identity', function () { return thisObject === thisLayer; });
snapshot('global.before');
observe('global.thisObject.volume-write', function () { thisObject.volume = 0.3; });
snapshot('global.after');
export function init(value) {
    if (!initObserved) {
        initObserved = true;
        emit('init.enter', {incomingType:typeof value});
        snapshot('init');
    }
}
export function update(value) {
    ++frame;
    if (!updateObserved) {
        updateObserved = true;
        emit('update.enter', {incomingType:typeof value});
        snapshot('update');
        emit('case-complete-observations-only', {initObserved:initObserved, updateObserved:updateObserved,
            inference:'public global/init/update observations only; no private stopped flag read'});
    }
}
