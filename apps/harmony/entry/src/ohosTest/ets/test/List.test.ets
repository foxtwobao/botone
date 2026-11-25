import assetSmoke from './AssetSmoke.test';
import sseSmoke from './SseSmoke.test';
import retryTest from './Retry.test';
import endpointTest from './Endpoint.test';
import sseParserTest from './SseParser.test';
import icuTest from './Icu.test';
import datesTest from './Dates.test';
import decodeTest from './Decode.test';
import modelDisplayTest from './ModelDisplay.test';
import sessionTest from './Session.test';
import netTest from './Net.test';
import sseTransportTest from './SseTransport.test';
import realBackendSmoke from './RealBackendSmoke.test';
import realThreadSmoke from './RealThreadSmoke.test';
import inboxProjectionTest from './InboxProjection.test';
import hotLocaleTest from './HotLocale.test';
import queryCacheTest from './QueryCache.test';
import rosterStreamTest from './RosterStream.test';
import saveControllerTest from './SaveController.test';
import rosterRealtimeTest from './RosterRealtime.test';
import threadReducerTest from './ThreadReducer.test';
import threadRenderTest from './ThreadRender.test';
import markdownFixtureTest from './MarkdownFixture.test';
import messageTextTest from './MessageText.test';
import threadWindowTest from './ThreadWindow.test';
import threadStreamTest from './ThreadStream.test';
import threadRealtimeTest from './ThreadRealtime.test';
import consentGateTest from './ConsentGate.test';
import attachmentsTest from './Attachments.test';

export default function testsuite() {
  // Pure-logic fixture replays: no network, no device state.
  retryTest();
  endpointTest();
  sseParserTest();
  icuTest();
  datesTest();
  decodeTest();
  modelDisplayTest();
  inboxProjectionTest();
  threadReducerTest();
  threadRenderTest();
  markdownFixtureTest();
  messageTextTest();
  threadWindowTest();
  hotLocaleTest();
  // Device storage and transport: need the fixture server (scripts/spike-sse-server.mjs,
  // ports 8787 and 8788) reachable at 10.0.2.2.
  assetSmoke();
  sessionTest();
  netTest();
  sseTransportTest();
  sseSmoke();
  queryCacheTest();
  rosterStreamTest();
  saveControllerTest();
  threadStreamTest();
  threadRealtimeTest();
  consentGateTest();
  attachmentsTest();
  rosterRealtimeTest();
  // Opt-in real-backend smokes; skip loudly without -s realBase.
  realBackendSmoke();
  realThreadSmoke();
}
