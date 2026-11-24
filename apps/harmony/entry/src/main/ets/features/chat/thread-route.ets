// The pending thread route: the inbox sets it just before pushing the 'thread' destination, and
// the destination reads it. Passing it out-of-band (rather than as the push param) keeps the
// navigation builder single-argument, matching the other destinations that push null.
export interface ThreadRoute {
  botId: string;
  groupId: string;
  title: string;
}

let pending: ThreadRoute = { botId: '', groupId: '', title: '' };

export function setThreadRoute(route: ThreadRoute): void {
  pending = route;
}

export function takeThreadRoute(): ThreadRoute {
  return pending;
}
