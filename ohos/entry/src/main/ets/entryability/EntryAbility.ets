
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { MobileScannerPlugin } from '../campuscard/scanner/MobileScannerPlugin';
import { CampusCardPlatformPlugin } from '../campuscard/CampusCardPlatformPlugin';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new MobileScannerPlugin())
    flutterEngine.getPlugins()?.add(new CampusCardPlatformPlugin())
  }
}
