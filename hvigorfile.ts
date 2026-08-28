import { appTasks, OhosPluginId, OhosAppContext } from '@ohos/hvigor-ohos-plugin';
import * as fs from 'fs';
import * as path from 'path';

const LOCAL_SIGNING_FILE = 'local-signing.json';

function applyLocalSigning(node: any): void {
  const projectPath: string = node.getNodePath();
  const localSigningPath = path.join(projectPath, LOCAL_SIGNING_FILE);
  if (!fs.existsSync(localSigningPath)) {
    console.log('[wqc-signing] local-signing.json not found, skip local signing injection.');
    return;
  }
  let material: any = null;
  try {
    const local = JSON.parse(fs.readFileSync(localSigningPath, 'utf-8'));
    material = local.material;
  } catch (error) {
    console.log('[wqc-signing] failed to parse local-signing.json, skip injection.');
    return;
  }
  if (!material) {
    console.log('[wqc-signing] local-signing.json has no material, skip injection.');
    return;
  }
  const context = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
  if (!context) {
    console.log('[wqc-signing] ohos app context is not ready, skip injection.');
    return;
  }
  const buildProfile = context.getBuildProfileOpt();
  const signingConfigs = buildProfile.app && buildProfile.app.signingConfigs;
  if (!signingConfigs || signingConfigs.length === 0) {
    console.log('[wqc-signing] no signingConfigs in build profile, skip injection.');
    return;
  }
  for (const signingConfig of signingConfigs) {
    signingConfig.material = material;
  }
  context.setBuildProfileOpt(buildProfile);
  console.log('[wqc-signing] injected local signing material into build profile.');
}

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [
    {
      pluginId: 'wqc-local-signing',
      apply: applyLocalSigning,
    }
  ]
}
