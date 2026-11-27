// The Space switch's decisions (A2): idle → switching → done | failed, and what each outcome
// leaves the selection holding. Pure and import-free, so the contract test replays it offline;
// the controller in space-switch-controller.ets performs the effects and reports back here.

/** What the controller reports to the machine. */
export interface SpaceSwitchEvent {
  /** select | retry | ok | disk_fail | net_fail | target_gone */
  kind: string;
  from: string;
  target: string;
}

/** One switch. `kept` is the Space the selection holds after the transition ('' when the 401
 * recovery owns the fallback); `reason` says why a failed switch failed. */
export interface SpaceSwitchState {
  /** idle | switching | done | failed */
  phase: string;
  from: string;
  target: string;
  kept: string;
  /** disk | unreachable | gone | '' */
  reason: string;
}

export function idleSwitchState(): SpaceSwitchState {
  const state: SpaceSwitchState = { phase: 'idle', from: '', target: '', kept: '', reason: '' };
  return state;
}

export function spaceSwitchEvent(kind: string, from: string, target: string): SpaceSwitchEvent {
  const event: SpaceSwitchEvent = { kind: kind, from: from, target: target };
  return event;
}

function settle(phase: string, state: SpaceSwitchState, kept: string, reason: string): SpaceSwitchState {
  const next: SpaceSwitchState = {
    phase: phase, from: state.from, target: state.target, kept: kept, reason: reason,
  };
  return next;
}

/**
 * One step of the switch. An event that does not fit the current phase leaves the state as it
 * is, so a late answer from a superseded step can never move it.
 */
export function spaceSwitchStep(state: SpaceSwitchState, event: SpaceSwitchEvent): SpaceSwitchState {
  if (state.phase === 'switching') {
    if (event.kind === 'ok') {
      return settle('done', state, state.target, '');
    }
    // The stored write failed: the claim rolls back to where the switch started.
    if (event.kind === 'disk_fail') {
      return settle('failed', state, state.from, 'disk');
    }
    // The server was unreachable: the new Space stays chosen, only the proof is missing.
    if (event.kind === 'net_fail') {
      return settle('failed', state, state.target, 'unreachable');
    }
    // The server no longer grants the target: the recovery owns the selection from here.
    if (event.kind === 'target_gone') {
      return settle('idle', state, '', 'gone');
    }
    return state;
  }
  if (event.kind === 'retry' && state.phase === 'failed' && state.reason === 'unreachable') {
    return settle('switching', state, state.target, '');
  }
  // Picking a Space starts from wherever the selection is; the same Space is not a switch.
  if (event.kind === 'select' && event.target !== '' && event.target !== event.from) {
    const next: SpaceSwitchState = {
      phase: 'switching', from: event.from, target: event.target, kept: event.target, reason: '',
    };
    return next;
  }
  return state;
}