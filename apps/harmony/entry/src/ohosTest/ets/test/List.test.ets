import assetSmoke from './AssetSmoke.test';
import sseSmoke from './SseSmoke.test';

export default function testsuite() {
  sseSmoke();
  assetSmoke();
}
