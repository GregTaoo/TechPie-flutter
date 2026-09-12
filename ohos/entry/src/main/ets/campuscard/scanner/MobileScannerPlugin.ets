/*
* Copyright (c) 2023 Shenzhen Kaihong Digital Industry Development Co., Ltd.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import {
  FlutterPlugin,
  FlutterPluginBinding
} from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, {
  MethodCallHandler,
  MethodResult
} from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import { AbilityAware, AbilityPluginBinding, ByteBuffer } from '@ohos/flutter_ohos/index';
import { UIAbility } from '@kit.AbilityKit';
import { cameraPermission, checkPermissions, requestPermissions } from './CameraPermissions';
import { customScan, scanBarcode, scanCore, detectBarcode } from '@kit.ScanKit';
import EventChannel, { EventSink } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import { Barcode, BarcodeFormat, BarcodeType } from './Barcode';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { Point } from '@ohos.UiTest';
import { hasFlashUnit, getCameraManager } from './CameraUtil';
import { image } from '@kit.ImageKit';
import { camera } from '@kit.CameraKit';

const TAG: string = "MobileScannerPlugin";

enum TorchState {
  off = 0,
  on = 1
}

export class MobileScannerPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  getUniqueClassName(): string {
    return "MobileScannerPlugin";
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    Log.i(TAG, "onAttachedToAbility");
    this.ability = binding.getAbility()
  }

  onDetachedFromAbility(): void {
    Log.i(TAG, "onDetachedFromAbility");
    this.ability = null;
  }

  private methodChannel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null
  private applicationContext: Context | null = null;
  private ability: UIAbility | null = null;
  private textureId: number | null = null;
  private surfaceId: string | null = null;
  private binding: FlutterPluginBinding | null = null;
  private isStart = false;
  private scanWidth: number = 1080 // 单位px
  private scanHeight: number = 1080 // 单位px
  private returnImage: boolean = false;
  private cameraResolutionValues: number[] | undefined = undefined;
  private resolutionRatio = [16/9,4/3,1];   //分辨率比例
  private torch: boolean = false
  private facing: number = 0
  private formats: number[] | undefined = undefined
  private speed: number = 1
  private timeout: number = 250
  private useNewCameraSelector: boolean = false
  private options: scanBarcode.ScanOptions = {};
  private retryScanTimes: number = 0;

  private scanWindow: Array<number> | null = null; // scanWindow，扫描区域
  private imageBuffer: Uint8Array | null = null;
  private isPaused:boolean = false

  publishEvent(event: ESObject) {
    this.eventSink?.success(event)
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.binding = binding;
    this.applicationContext = binding.getApplicationContext();
    this.methodChannel =
      new MethodChannel(binding.getBinaryMessenger(), "dev.steenbakker.mobile_scanner/scanner/method");
    this.methodChannel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(binding.getBinaryMessenger(), "dev.steenbakker.mobile_scanner/scanner/event");
    this.eventChannel.setStreamHandler({
      onListen: (args: Object, eventSink: EventSink) => {
        this.eventSink = eventSink;
      },
      onCancel: () => {
      }
    });
    // texture
    const textureRegistry = this.binding!.getTextureRegistry();
    this.textureId = textureRegistry.getTextureId();
    const surfaceTextureEntry = textureRegistry.registerTexture(this.textureId);
    this.surfaceId = surfaceTextureEntry.getSurfaceId().toString();
    Log.i(TAG, `surfaceId: ${this.surfaceId}`)
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.applicationContext = null;
    this.methodChannel?.setMethodCallHandler(null);
    this.methodChannel = null;
    this.eventChannel?.setStreamHandler(null);
    this.eventChannel = null;
    this.isStart = false;
    this.scanWindow = null;
    this.imageBuffer = null;
    binding.getTextureRegistry().unregisterTexture(this.textureId);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    try {
      if (call.method === "state") {
        checkPermissions(cameraPermission).then(hasCameraPermission => {
          if (hasCameraPermission) {
            result.success(1)
          } else {
            result.success(2)
          }
        }).catch((error: BusinessError) => {
          result.error(String(error.code), error.message, null);
        });
      } else if (call.method === "request") {
        requestPermissions(this.ability!.context, (err, msg) => {
          if (err) {
            result.success(false)
          } else {
            result.success(true)
          }
        });
      } else if (call.method === "start") {
        this.start(call, result).catch((error: BusinessError) => {
          this.isStart = false;
          result.error('MOBILE_SCANNER_CAMERA_ERROR', error.message, null);
        })
      } else if (call.method === "torch"|| call.method === "toggleTorch") {
        this.toggleTorch(call, result)
      } else if (call.method === "stop") {
        this.stop(result)
      } else if (call.method === "analyzeImage") {
        this.analyzeImage(call, result)
      } else if (call.method === "setScale") {
        this.setScale(call, result)
      } else if (call.method === "resetScale") {
        this.resetScale(result)
      } else if (call.method === "updateScanWindow") {
        this.updateScanWindow(call, result)
      }  else if (call.method === "pause") {
        this.pause(call, result)
      } else {
        result.notImplemented()
      }
    } catch (err) {
      result.error("Name not found", err.message, null)
    }
  }

  async start(call: MethodCall, result: MethodResult) {
    this.torch = call.argument("torch") ?? false
    this.facing = call.argument("facing") ?? 0
    this.formats = call.argument("formats")
    this.returnImage = call.argument("returnImage") ?? false
    this.speed = call.argument("speed") ?? 1
    this.timeout = call.argument("timeout") ?? 250
    this.cameraResolutionValues = call.argument("cameraResolution")
    this.useNewCameraSelector = call.argument("useNewCameraSelector") ?? false

    this.scanWindow = null;
    this.retryScanTimes = 0;
    this.isStart = true;
    let scanTypes = [scanCore.ScanType.ALL]
    if (this.formats) {
      scanTypes = []
      this.formats.forEach((format: number) => {
        let type = Barcode.convertToScanType(format)
        if (type != scanCore.ScanType.FORMAT_UNKNOWN) {
          scanTypes.push(type)
        }
      })
    }
    this.options = {
      scanTypes: scanTypes,
      enableMultiMode: true,
      enableAlbum: true
    }
    this.startCamera();
    // dart 中接收的 width 和 height 会转换为 double 类型，返回整数会导致异常
    result.success({
      "textureId": this.textureId,
      "size": {
        "width": this.scanWidth,
        "height": this.scanHeight
      },
      "torchable": this.readTorchState() >= 0,
      "numberOfCameras": 1,
      "currentTorchState": this.readTorchState()
    });
  }

  // 重启相机流
  retryCamera(error: BusinessError) {
    if (this.retryScanTimes < 3 && error.code === scanCore.ScanErrorCode.INTERNAL_ERROR) {
      this.retryScanTimes++;
      let timeId = setTimeout(async () => {
        // 先暂停并释放相机流
        await this.stop(null);
        // 重启相机流
        this.startCamera();
        clearTimeout(timeId);
      }, 100)
    }
  }
  // 启动相机流
  startCamera() {
    customScan.init(this.options);
    this.setDisplay()
    this.startScan()
    if (this.torch && this.readTorchState() >= 0) {
      customScan.openFlashLight()
    }
    this.publishEvent({
      name: 'torchState',
      data: this.readTorchState()
    });
  }

  // 返回自定义扫描结果的回调
  private scanCallback: AsyncCallback<scanBarcode.ScanResult[]> =
    async (error: BusinessError, result: scanBarcode.ScanResult[]) => {
      if (error && error.code) {
        Log.e(TAG, `Failed to get ScanResult by callback. Code: ${error.code}, message: ${error.message}`);
        this.retryCamera(error);
        return;
      }
      // 解析码值结果跳转应用服务页
      const _r: Barcode[] = result.map(item => {
        let size:ESObject = {
          width:this.toDoubleType(item.scanCodeRect!.right - item.scanCodeRect!.left),
          height:this.toDoubleType(item.scanCodeRect!.bottom - item.scanCodeRect!.top)
        };

        return {
          displayValue: item.originalValue,
          rawValue: item.originalValue,
          format: Barcode.convertScanType(item.scanType),
          type: BarcodeType.unknown,
          corners: [
            { x: this.toDoubleType(item.scanCodeRect!.left),  y: this.toDoubleType(item.scanCodeRect!.top) } as Point,
            { x: this.toDoubleType(item.scanCodeRect!.right),  y: this.toDoubleType(item.scanCodeRect!.top) } as Point,
            { x: this.toDoubleType(item.scanCodeRect!.right),  y: this.toDoubleType(item.scanCodeRect!.bottom) } as Point,
            { x: this.toDoubleType(item.scanCodeRect!.left),  y: this.toDoubleType(item.scanCodeRect!.bottom) } as Point,
          ],
          size:size
        } as Barcode;
      })
      this.callback(_r, this.imageBuffer, this.scanWidth, this.scanHeight);
    }
  // 返回相机帧的回调
  private frameCallback: AsyncCallback<customScan.ScanFrame> =
    async (error: BusinessError, frameResult: customScan.ScanFrame) => {
      this.imageBuffer = null;
      if (error) {
        Log.e(TAG, `Failed to get ScanFrame by callback. Code: ${error.code}, message: ${error.message}`);
        return;
      }
      if (frameResult && this.returnImage) {
        try {
          const EventWidth = frameResult.width;
          const EventHeight = frameResult.height;

          let sourcePotions: image.SourceOptions = {
            sourceDensity: 120,
            sourcePixelFormat: image.PixelMapFormat.NV21,
            sourceSize: { height: EventHeight, width: EventWidth }
          }
          let imageResource = image.createImageSource(frameResult.byteBuffer, sourcePotions)
          let opts: image.InitializationOptions = {
            editable: true,
            pixelFormat: image.PixelMapFormat.RGBA_8888,
            size: { height: EventHeight, width: EventWidth }
          }
          let pixelMap: image.PixelMap = await imageResource.createPixelMap(opts)
          // 修正相机预览流方向
          pixelMap.rotateSync(camera.ImageRotation.ROTATION_90)
          let packer: image.ImagePacker = image.createImagePacker()
          let packingOpt: image.PackingOption = { format: "image/jpeg", quality: 100 }
          let imgBuffer = await packer.packing(pixelMap, packingOpt);
          this.imageBuffer = new Uint8Array(imgBuffer)
        } catch (e) {
          Log.e(TAG, `Failed to create imageBuffer`);
        }
      }
    }

  startScan() {
    try {
      const viewControl: customScan.ViewControl = {
        width: this.scanWidth,
        height: this.scanHeight,
        surfaceId: this.surfaceId!,
      };
      customScan.start(viewControl, this.scanCallback, this.frameCallback)
    } catch (err) {
      Log.e(TAG, `Failed to start scan: ${err.message}`)
      throw new Error(err.message);
    }
  }

  // 竖屏时获取屏幕尺寸，设置预览流全屏示例
  setDisplay() {
    // 以手机为例计算宽高
    let displayClass = display.getDefaultDisplaySync();
    if (displayClass !== null) {
      let orientation = displayClass.orientation.valueOf()
      if (!!this.cameraResolutionValues && this.cameraResolutionValues.length >= 2) {
        let width = this.cameraResolutionValues[0];
        let height = this.cameraResolutionValues[1];
        if (orientation === 0 || orientation === 2) {
          let radio = height / width;
          this.scanWidth = this.toDoubleType(px2vp(displayClass.width));
          if (radio <= this.resolutionRatio[2]) {
            this.scanHeight = this.scanWidth;
          }else if (radio <= this.resolutionRatio[1]) {
            this.scanHeight = this.scanWidth * this.resolutionRatio[1];
          }else {
            this.scanHeight = this.scanWidth * this.resolutionRatio[0];
          }
        }else {
          let radio = width / height;
          this.scanHeight = this.toDoubleType(px2vp(displayClass.height));
          if (radio <= this.resolutionRatio[2]) {
            this.scanWidth = this.scanHeight;
          }else if (radio <= this.resolutionRatio[1]) {
            this.scanWidth = this.scanHeight * this.resolutionRatio[1];
          }else {
            this.scanWidth = this.scanHeight * this.resolutionRatio[0];
          }
        }
      }else {
        if (orientation === 0 || orientation === 2) {
          this.scanWidth = this.toDoubleType(px2vp(displayClass.width));
          this.scanHeight = this.scanWidth;
        }else {
          this.scanHeight = this.toDoubleType(px2vp(displayClass.height));
          this.scanWidth = this.scanHeight;
        }
      }
    }
  }

  toDoubleType(number: number): number {
    if (Number.isInteger(number)){
      number += 0.00000000001
    }
    return number;
  }

  async pause(call: MethodCall, result: MethodResult) {
    let force: boolean = call.argument("force") ?? false

    if (this.isStart || force) {
      await customScan.stop();
      await customScan.release();
      this.isPaused = true;
    }

    result?.success(null)
  }

  async stop(result: MethodResult | null) {
    if (this.isStart || this.isPaused) {
      this.isPaused = false;
      try {
        this.isStart = false;
        await customScan.stop();
        await customScan.release();
      } catch (e) {
        try {
          await customScan.release();
        } catch (e) {
          this.isStart = true;
        }
      }
    }
    result?.success(null)
  }

  private readTorchState(): number {
    try {
      return customScan.getFlashLightStatus() ? TorchState.on : TorchState.off;
    } catch (_) {
      return -1; // A missing flash must not prevent camera preview or decoding.
    }
  }

  toggleTorch(call: MethodCall, result: MethodResult) {
    const state = this.readTorchState();
    if (state < 0) {
      result.error('MOBILE_SCANNER_UNSUPPORTED_OPERATION', 'Flashlight unavailable', null);
      return;
    }
    const light = state === TorchState.on;
    if (light) {
      customScan.closeFlashLight()
    } else {
      customScan.openFlashLight()
    }
    this.publishEvent({
      name: 'torchState',
      data: this.readTorchState()
    });
    result.success(null)
  }

  analyzeImage(call: MethodCall, result: MethodResult) {
    let formats:number[] = call.argument("formats")
    let filePath: string = call.argument("filePath")

    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: true,
      enableAlbum: true
    }
    let inputImage: detectBarcode.InputImage = { uri: filePath }
    detectBarcode.decode(inputImage, options, (error: BusinessError, scanResult: Array<scanBarcode.ScanResult>) => {
      if (error && error.code) {
        result.error("MOBILE_SCANNER_BARCODE_ERROR", JSON.stringify(error) , null)
        return
      }
      if (scanResult.length == 0) {
        result.success({
          name: 'barcode',
          data: null
        })
        return
      }
      const barcodes: Barcode[] = scanResult.map(item => {
        let cornerPoints = item.cornerPoints;
        let corners: Array<Point> = []
        if (cornerPoints != undefined && cornerPoints != null) {
          corners = [
            { x: this.toDoubleType(this.scanWidth - cornerPoints[0].y), y: this.toDoubleType(cornerPoints[0].x)},
            { x: this.toDoubleType(this.scanWidth - cornerPoints[1].y), y: this.toDoubleType(cornerPoints[1].x)},
            { x: this.toDoubleType(this.scanWidth - cornerPoints[2].y), y: this.toDoubleType(cornerPoints[2].x)},
            { x: this.toDoubleType(this.scanWidth - cornerPoints[3].y), y: this.toDoubleType(cornerPoints[3].x)},
          ]
        }

        let size:ESObject = {
          width:this.toDoubleType(item.scanCodeRect!.right - item.scanCodeRect!.left),
          height:this.toDoubleType(item.scanCodeRect!.bottom - item.scanCodeRect!.top)
        }
        return {
          displayValue: item.originalValue,
          rawValue: item.originalValue,
          format: Barcode.convertScanType(item.scanType),
          type: BarcodeType.unknown,
          corners: corners,
          size: size
        } as Barcode;
      });
      result.success({
        name: 'barcode',
        data: barcodes
      })
    })
  }

  setScale(call: MethodCall, result: MethodResult) {
    let zoomValue: number = call.args as number;
    try {
      customScan.setZoom(zoomValue);
      result.success(true);
    } catch (error) {
      result.success(false);
    }
  }

  resetScale(result: MethodResult) {
    try {
      customScan.setZoom(1);
      result.success(true);
    } catch (error) {
      result.success(false);
    }
  }

  updateScanWindow(call: MethodCall, result: MethodResult) {
    this.scanWindow = call.argument("rect")
    result.success(null)
  }

  callback(barcodes: Barcode[], image: Uint8Array | null, width: number, height: number) {
    barcodes = barcodes.filter(barcode => {
      if (this.scanWindow) {
        return this.isBarcodeInScanWindow(barcode);
      } else {
        return true;
      }
    });
    if (barcodes.length == 0) {
      customScan.rescan();
    }

    if(!this.returnImage) {
      image = null
    }

    let imageinfo:ESObject = {
      bytes:image,
      width: width,
      height: height
    }

    this.publishEvent({
      "name": "barcode",
      "data": barcodes,
      "image": imageinfo
    })

    // 扫描完成后需要调用重新扫描继续识别
    setTimeout(() => {
      if (this.isStart && !this.isPaused) {
        try {
          customScan.rescan();
        } catch (err) {
          Log.e(TAG, `Failed to rescan: ${err.message}`)
        }
      }
    }, this.returnImage ? 250 : 100);
  }

  private isBarcodeInScanWindow(barcode: Barcode): boolean {
    const corners = barcode.corners;
    const left = Math.round(this.scanWindow![0] * this.scanWidth);
    const top = Math.round(this.scanWindow![1] * this.scanHeight);
    const right = Math.round(this.scanWindow![2] * this.scanWidth);
    const bottom = Math.round(this.scanWindow![3] * this.scanHeight);
    return corners.reduce((r, item) => r && item.x >= left && item.x <= right && item.y >= top && item.y <= bottom,
      true)
  }

  errorCallback(error: string) {
    this.publishEvent({
      "name": "error",
      "data": error
    })
  }

  torchCallback(error: BusinessError, bool: boolean) {
    if (error) {
      return;
    }
    this.publishEvent({
      name: 'torchState',
      data: this.readTorchState()
    });
  }
}
