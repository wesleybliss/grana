import CoreLocation
import Flutter
import UIKit
import Vision

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct GenerableScannedItem {
  @Guide(description: "Exact numeric price text as printed on the sign or tag")
  var rawText: String

  @Guide(description: "True numeric value after resolving thousands separators or k shorthand")
  var normalizedAmount: Double

  @Guide(description: "3-letter ISO currency code such as DOP, USD, EUR, MXN, or JPY")
  var currencyCode: String

  @Guide(description: "True if shorthand like 18k or inflated 1000x menu notation was expanded")
  var isShorthandMultiplied: Bool
}

@available(iOS 26.0, *)
@Generable
struct GenerableMenuScan {
  @Guide(description: "Inferred 3-letter ISO currency code for the prices")
  var inferredCurrency: String

  @Guide(description: "Detected numeric prices only, excluding calories, weights, dates, or percentages")
  var items: [GenerableScannedItem]
}

@available(iOS 26.0, *)
struct ConvertCurrencyTool: Tool {
  let name = "convert_currency"
  let description = "Converts an amount from one 3-letter ISO currency code to another using Grana's cached offline rates."

  let ratesBySymbol: [String: Double]

  @Generable
  struct Arguments {
    @Guide(description: "Numeric amount to convert")
    var amount: Double
    @Guide(description: "Source 3-letter ISO currency code")
    var fromCurrency: String
    @Guide(description: "Target 3-letter ISO currency code")
    var toCurrency: String
  }

  func call(arguments: Arguments) async throws -> String {
    let from = arguments.fromCurrency.uppercased()
    let to = arguments.toCurrency.uppercased()
    let fromRate = from == "USD" ? 1.0 : (ratesBySymbol[from] ?? 1.0)
    let toRate = to == "USD" ? 1.0 : (ratesBySymbol[to] ?? 1.0)
    let usd = fromRate > 0 ? arguments.amount / fromRate : arguments.amount
    let converted = (to == "USD" ? usd : usd * toRate)
    return String(format: "%.2f %@", converted, to)
  }
}

@available(iOS 26.0, *)
struct TipAndSplitTool: Tool {
  let name = "calculate_tip_and_split"
  let description = "Adds a tip percentage to a subtotal and divides across splitCount people."

  @Generable
  struct Arguments {
    var subtotal: Double
    var tipPercent: Double
    var splitCount: Int
  }

  func call(arguments: Arguments) async throws -> String {
    let safeSplit = max(1, arguments.splitCount)
    let perPerson = (arguments.subtotal * (1.0 + arguments.tipPercent / 100.0)) / Double(safeSplit)
    return String(format: "%.2f", perPerson)
  }
}
#endif

final class IosPriceScannerPlugin: NSObject, CLLocationManagerDelegate {
  private let locationManager = CLLocationManager()
  private var pendingLocationContinuations: [(CLLocation?) -> Void] = []

  override init() {
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
  }

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.gammagamma.grana/price_scanner",
      binaryMessenger: controller.binaryMessenger
    )
    let instance = IosPriceScannerPlugin()
    channel.setMethodCallHandler(instance.handle(_:result:))
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCapabilities":
      result(checkCapabilities())

    case "detectLocationCurrency":
      let args = call.arguments as? [String: Any]
      let requestPermission = (args?["requestPermission"] as? Bool) ?? false
      detectLocationCurrency(requestPermission: requestPermission, result: result)

    case "downloadModel":
      // Apple Intelligence weights are managed directly by iOS
      result(checkCapabilities()["llmStatus"] as? String == "available")

    case "recognizeLiveFrame":
      guard let args = call.arguments as? [String: Any],
            let typedBytes = args["bytes"] as? FlutterStandardTypedData,
            let width = args["width"] as? Int,
            let height = args["height"] as? Int else {
        result([:])
        return
      }
      let bytesPerRow = (args["bytesPerRow"] as? Int) ?? (width * 4)
      DispatchQueue.global(qos: .userInitiated).async {
        let lines = self.recognizeBgraFrame(
          data: typedBytes.data,
          width: width,
          height: height,
          bytesPerRow: bytesPerRow
        )
        DispatchQueue.main.async {
          result([
            "lines": lines,
            "imageWidth": width,
            "imageHeight": height,
          ])
        }
      }

    case "analyzeImageSmart":
      guard let args = call.arguments as? [String: Any],
            let imagePath = args["imagePath"] as? String,
            let uiImage = UIImage(contentsOfFile: imagePath),
            let cgImage = uiImage.cgImage else {
        result([:])
        return
      }
      let selectedCurrencies = (args["selectedCurrencies"] as? [String]) ?? ["USD"]
      let lockedCurrency = args["lockedSourceCurrency"] as? String
      let locationCurrency = args["locationCurrency"] as? String

      Task {
        let lines = self.recognizeCgImage(cgImage, accurate: true)
        let ocrJoined = lines.compactMap { $0["text"] as? String }.joined(separator: "\n")

        var aiItems: [[String: Any]] = []
        var inferredCurrency: String? = nil
        var tierUsed = "onDeviceOcr"

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
          do {
            let session = LanguageModelSession(
              instructions: "Extract ONLY numeric prices and their 3-letter ISO currency code. Do NOT transcribe or translate item names or other text."
            )
            let currencyRule: String
            if let locked = lockedCurrency, !locked.isEmpty {
              currencyRule = "Source currency is locked to \(locked)."
            } else if let loc = locationCurrency, !loc.isEmpty {
              currencyRule = "The user's current location currency is \(loc). Use \(loc) unless an explicit currency symbol or ISO code specifies otherwise."
            } else {
              currencyRule = "Infer currency from explicit symbols or ISO codes. User favorite currencies: \(selectedCurrencies.joined(separator: ", "))."
            }
            let prompt = """
            Extract ONLY numeric prices from this OCR text. Do not extract or translate item names or descriptions.
            \(currencyRule)
            Treat a dot or comma followed by 3 digits (such as "$1.350", "$1.300", "28.000", "1,350") as a thousands separator (1350, 1300, 28000), NOT a decimal (except for 3-decimal currencies like KWD/BHD/OMR/JOD).
            Ignore calories, weights, percentages, dates, years, and phone numbers.

            OCR text:
            \(ocrJoined)
            """
            let generated = try await session.respond(
              to: prompt,
              generating: GenerableMenuScan.self
            )
            let scan = generated.content
            inferredCurrency = scan.inferredCurrency
            tierUsed = "appleIntelligence"
            aiItems = scan.items.map { item in
              [
                "rawText": item.rawText,
                "normalizedAmount": item.normalizedAmount,
                "currencyCode": item.currencyCode,
                "isShorthandMultiplied": item.isShorthandMultiplied,
              ]
            }
          } catch {
            // Fall back cleanly to deterministic OCR lines
          }
        }
        #endif

        DispatchQueue.main.async {
          result([
            "lines": lines,
            "imageWidth": cgImage.width,
            "imageHeight": cgImage.height,
            "tierUsed": tierUsed,
            "inferredCurrency": inferredCurrency as Any,
            "aiItems": aiItems,
          ])
        }
      }

    case "askAgent":
      guard let args = call.arguments as? [String: Any],
            let prompt = args["prompt"] as? String else {
        result(["handledByNativeAgent": false])
        return
      }
      let sourceCurrency = (args["sourceCurrency"] as? String) ?? "USD"
      let selectedCurrencies = (args["selectedCurrencies"] as? [String]) ?? ["USD"]
      let rates = (args["ratesBySymbol"] as? [String: Double]) ?? [:]
      let items = (args["items"] as? [[String: Any]]) ?? []

      Task {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
          do {
            let session = LanguageModelSession(
              tools: [
                ConvertCurrencyTool(ratesBySymbol: rates),
                TipAndSplitTool(),
              ],
              instructions: "You are Grana's on-device currency assistant. Use tools for exact conversions and tip/split math. Keep answers concise."
            )
            let summary = items.map { "- \($0["label"] ?? ""): \($0["amount"] ?? 0) \(sourceCurrency)" }.joined(separator: "\n")
            let fullPrompt = """
            Scanned items (\(sourceCurrency)):
            \(summary)
            Target currencies: \(selectedCurrencies.joined(separator: ", "))

            User request: \(prompt)
            """
            let reply = try await session.respond(to: fullPrompt)
            DispatchQueue.main.async {
              result([
                "handledByNativeAgent": true,
                "responseText": reply.content,
                "invokedTools": ["apple_foundation_models"],
              ])
            }
            return
          } catch {
            // Fall through to Dart deterministic calculator
          }
        }
        #endif

        DispatchQueue.main.async {
          result(["handledByNativeAgent": false])
        }
      }

    case "disposeSession":
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func detectLocationCurrency(requestPermission: Bool, result: @escaping FlutterResult) {
    let status = locationManager.authorizationStatus
    if status == .authorizedWhenInUse || status == .authorizedAlways {
      if let cached = locationManager.location {
        reverseGeocode(location: cached, result: result)
        return
      }
      pendingLocationContinuations.append { [weak self] loc in
        if let loc = loc {
          self?.reverseGeocode(location: loc, result: result)
        } else {
          result(self?.fallbackLocaleCurrency() ?? [:])
        }
      }
      locationManager.requestLocation()
      return
    }

    if requestPermission && status == .notDetermined {
      locationManager.requestWhenInUseAuthorization()
    }
    result(fallbackLocaleCurrency())
  }

  private func reverseGeocode(location: CLLocation, result: @escaping FlutterResult) {
    CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, _ in
      if let country = placemarks?.first?.isoCountryCode?.uppercased(),
         let currency = self?.currencyForCountry(country) {
        DispatchQueue.main.async {
          result([
            "currencyCode": currency,
            "countryCode": country,
            "source": "gps",
          ])
        }
      } else {
        DispatchQueue.main.async {
          result(self?.fallbackLocaleCurrency() ?? [:])
        }
      }
    }
  }

  private func currencyForCountry(_ countryCode: String) -> String? {
    let locale = Locale(identifier: "en_\(countryCode)")
    if #available(iOS 16.0, *) {
      return locale.currency?.identifier
    }
    return locale.currencyCode
  }

  private func fallbackLocaleCurrency() -> [String: Any] {
    let country: String?
    if #available(iOS 16.0, *) {
      country = Locale.current.region?.identifier
    } else {
      country = Locale.current.regionCode
    }
    if let country = country, let currency = currencyForCountry(country) {
      return [
        "currencyCode": currency,
        "countryCode": country,
        "source": "locale",
      ]
    }
    return [:]
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    let loc = locations.last
    let callbacks = pendingLocationContinuations
    pendingLocationContinuations.removeAll()
    callbacks.forEach { $0(loc) }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    let callbacks = pendingLocationContinuations
    pendingLocationContinuations.removeAll()
    callbacks.forEach { $0(nil) }
  }

  private func checkCapabilities() -> [String: Any] {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      if case .available = SystemLanguageModel.default.availability {
        return [
          "isSupported": true,
          "activeTier": "appleIntelligence",
          "llmStatus": "available",
        ]
      }
    }
    #endif
    return [
      "isSupported": true,
      "activeTier": "onDeviceOcr",
      "llmStatus": "unavailable",
    ]
  }

  private func recognizeBgraFrame(
    data: Data,
    width: Int,
    height: Int,
    bytesPerRow: Int
  ) -> [[String: Any]] {
    guard let provider = CGDataProvider(data: data as CFData),
          let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
      return []
    }
    return recognizeCgImage(cgImage, accurate: false)
  }

  private func recognizeCgImage(_ cgImage: CGImage, accurate: Bool) -> [[String: Any]] {
    var extracted: [[String: Any]] = []
    let request = VNRecognizeTextRequest { req, _ in
      guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
      for obs in observations {
        guard let topCandidate = obs.topCandidates(1).first else { continue }
        let box = obs.boundingBox
        // Convert Vision bottom-left origin to top-left normalized coordinates
        let topLeftY = max(0.0, min(1.0, 1.0 - box.origin.y - box.size.height))
        extracted.append([
          "text": topCandidate.string,
          "boundingBox": [
            "left": max(0.0, min(1.0, box.origin.x)),
            "top": topLeftY,
            "width": max(0.0, min(1.0, box.size.width)),
            "height": max(0.0, min(1.0, box.size.height)),
          ],
        ])
      }
    }
    request.recognitionLevel = accurate ? .accurate : .fast
    request.usesLanguageCorrection = accurate
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([request])
    return extracted
  }
}
