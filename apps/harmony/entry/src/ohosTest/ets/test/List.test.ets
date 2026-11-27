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
import voiceTest from './Voice.test';
import voiceHostedTest from './VoiceHosted.test';
import dictationLifecycleTest from './DictationLifecycle.test';
import voiceClipTest from './VoiceClip.test';
import deviceSpeechTest from './DeviceSpeech.test';
import clipPlayerTest from './ClipPlayer.test';
import voiceSettingsTest from './VoiceSettings.test';
import signInViewTest from './SignInView.test';
import groupRulesTest from './GroupRules.test';
import groupWriteTest from './GroupWrite.test';
import modelConnectTest from './ModelConnect.test';
import modelWriteTest from './ModelWrite.test';
import spaceSelectionTest from './SpaceSelection.test';

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
  signInViewTest();
  threadReducerTest();
  threadRenderTest();
  markdownFixtureTest();
  messageTextTest();
  threadWindowTest();
  hotLocaleTest();
  // M8: the group rules' contract-generated default name and the member decode (pure).
  groupRulesTest();
  // M9: the model connection ports' fixture replay (pure).
  modelConnectTest();
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
  // M8: the group create/update writes against the fixture server.
  groupWriteTest();
  // M9: the model connections store against the fixture server.
  modelWriteTest();
  // M10 A1: the selected Space's persistence, isolation and stale-Space recovery.
  spaceSelectionTest();
  // Opt-in real-backend smokes; skip loudly without -s realBase.
  realBackendSmoke();
  realThreadSmoke();
  // M7: the voice ports' fixture replay (pure), then the hosted loop against the fixture server.
  voiceTest();
  voiceHostedTest();
  // M7 review round 2: the dictation lifecycles and send semantics, both paths.
  dictationLifecycleTest();
  // M7 review round 4: the recording, the device synthesizer and the clip player on scripted
  // hardware, then the Voice settings store against the fixture server.
  voiceClipTest();
  deviceSpeechTest();
  clipPlayerTest();
  voiceSettingsTest();
}
