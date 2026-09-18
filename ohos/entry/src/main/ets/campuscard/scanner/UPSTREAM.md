Native OHOS implementation from OpenHarmony-SIG fluttertpc_mobile_scanner, branch br_v6.0.10_ohos, commit eb450cf85a2f31dd8921aadceaf181a94ac57cee.

Source: https://gitcode.com/openharmony-sig/fluttertpc_mobile_scanner

The source files retain their Apache-2.0 notices. Only the OHOS implementation is vendored; TechPie keeps mobile_scanner 7.0.0-beta.6 for Dart, Android and iOS.

Local adaptation: return asynchronous camera startup failures through MethodResult instead of leaving the Dart call unresolved.
Local adaptation: unsupported flash APIs report an unavailable torch and do not prevent scanning; synchronous scan startup errors propagate to MethodResult.
