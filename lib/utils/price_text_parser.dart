import 'package:grana/domain/models/scanned_price.dart';
import 'package:grana/utils/currency_utils.dart';

/// Deterministic cross-platform parser that extracts numeric prices,
/// regional decimal/thousands numbers, and currency symbols from OCR lines.
///
/// Strictly focuses on price & currency extraction (no text/menu labeling or translation).
class PriceTextParser {
  /// Currencies that legitimately display 3 fractional decimal places on
  /// menus and price tags (fils / baisa / millimes).
  static const Set<String> threeDecimalCurrencies = {
    'BHD',
    'JOD',
    'KWD',
    'LYD',
    'OMR',
    'TND',
  };

  /// 3-decimal currencies that commonly use comma as the decimal separator.
  static const Set<String> _commaThreeDecimalCurrencies = {'LYD', 'TND'};

  static const Set<String> knownIsoCodes = {
    'USD', 'EUR', 'GBP', 'JPY', 'CNY', 'KRW', 'CAD', 'AUD', 'NZD', 'CHF',
    'HKD', 'TWD', 'SGD', 'MXN', 'COP', 'BRL', 'ARS', 'CLP', 'PEN', 'UYU',
    'CRC', 'DOP', 'GTQ', 'BOB', 'PYG', 'PAB', 'HNL', 'NIO', 'JMD', 'TTD',
    'BBD', 'BSD', 'BZD', 'HTG', 'CUP', 'AWG', 'XCD',
    'THB', 'VND', 'IDR', 'MYR', 'PHP', 'INR', 'PKR', 'LKR', 'NPR', 'BDT',
    'SEK', 'NOK', 'DKK', 'ISK', 'PLN', 'CZK', 'HUF', 'RON', 'BGN', 'TRY',
    'ILS', 'AED', 'SAR', 'QAR', 'KWD', 'BHD', 'OMR', 'JOD', 'EGP', 'MAD',
    'ZAR', 'NGN', 'KES', 'GHS', 'UAH', 'GEL', 'LAK', 'KHR',
  };

  /// Unambiguous prefix/suffix symbols mapped directly to ISO currency codes.
  static const Map<String, String> unambiguousSymbols = {
    'RD\$': 'DOP',
    'DOP\$': 'DOP',
    'US\$': 'USD',
    'USD\$': 'USD',
    'CA\$': 'CAD',
    'C\$': 'CAD',
    'AU\$': 'AUD',
    'A\$': 'AUD',
    'NZ\$': 'NZD',
    'HK\$': 'HKD',
    'NT\$': 'TWD',
    'S\$': 'SGD',
    'MX\$': 'MXN',
    'MEX\$': 'MXN',
    'COL\$': 'COP',
    'CLP\$': 'CLP',
    'AR\$': 'ARS',
    'U\$S': 'UYU',
    'UY\$': 'UYU',
    'J\$': 'JMD',
    'TT\$': 'TTD',
    'BZ\$': 'BZD',
    'EC\$': 'XCD',
    'B/.': 'PAB',
    'R\$': 'BRL',
    'S/.': 'PEN',
    'S/': 'PEN',
    'CHF': 'CHF',
    'Fr.': 'CHF',
    '€': 'EUR',
    '£': 'GBP',
    '₩': 'KRW',
    '₹': 'INR',
    '฿': 'THB',
    '₫': 'VND',
    '₺': 'TRY',
    '₱': 'PHP',
    '₪': 'ILS',
    '₴': 'UAH',
    '₦': 'NGN',
    'zł': 'PLN',
    'Kč': 'CZK',
    'Ft': 'HUF',
    'Rp': 'IDR',
    'RM': 'MYR',
    '₡': 'CRC',
    '₲': 'PYG',
  };

  /// Ambiguous currency symbols ordered by common candidate currencies.
  static const Map<String, List<String>> ambiguousSymbols = {
    '\$': [
      'USD',
      'DOP',
      'MXN',
      'COP',
      'CAD',
      'AUD',
      'CLP',
      'ARS',
      'UYU',
      'SGD',
      'HKD',
      'TWD',
      'NZD',
      'JMD',
      'TTD',
      'BBD',
      'BSD',
      'BZD',
      'XCD',
      'NAD',
    ],
    '¥': ['JPY', 'CNY'],
    '￥': ['JPY', 'CNY'],
    'kr': ['SEK', 'NOK', 'DKK', 'ISK'],
    'Kr': ['SEK', 'NOK', 'DKK', 'ISK'],
    'KR': ['SEK', 'NOK', 'DKK', 'ISK'],
  };

  // Matches noise lines that should NOT be treated as standalone prices.
  static final RegExp _noiseLinePattern = RegExp(
    r'^(\+?\d[\d\s\-()]{6,}\d|' // Phone numbers
    r'\d{1,2}:\d{2}(\s?[aApP][mM])?|' // Clock times
    r'\d{1,4}[/\-]\d{1,2}[/\-]\d{1,4}|' // Dates
    r'\d+(\.\d+)?\s?%)$', // Pure percentages
  );

  static final RegExp _unitNoiseSuffix = RegExp(
    r'^\s*(kcal|cal|kj|ml|cl|dl|l|oz|fl\s?oz|g|gr|kg|mg|lb|lbs|cm|mm|m|km|%|°|pcs|pc|pk|un|und|uds|pzs|yr|yrs|años|anos|dias|días|meses|min|mins|hr|hrs|hs|h|am|pm|x)\b',
    caseSensitive: false,
  );

  static final RegExp _noisePrefixPattern = RegExp(
    r'(#|no\.?|n°|nro\.?|tel\.?|cel\.?|calle|av\.?|km|since|est\.?|founded|©|v)\s*$',
    caseSensitive: false,
  );

  // Captures optional prefix currency, numeric token (with separators + optional k/K shorthand
  // or Swiss .- suffix), and optional suffix currency.
  static final RegExp _priceCandidateRegex = RegExp(
    r'(?<prefix>(?:RD\$|DOP\$|US\$|USD\$|CA\$|AU\$|NZ\$|HK\$|NT\$|MX\$|MEX\$|COL\$|CLP\$|AR\$|U\$S|UY\$|J\$|TT\$|BZ\$|EC\$|B/\.|R\$|C\$|A\$|S\$|S/\.|S/|CHF|Fr\.|Rp|RM|[A-Z]{3}|[€£¥￥₩₹฿₫₺₱₪₴₦₡₲\$])\s*)?'
    r'(?<number>\d{1,3}(?:[.,\s]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)'
    r'(?<swiss>\s?[.,][\-–—])?'
    r'(?<kSuffix>[kK]\b)?'
    r'(?<suffix>\s*(?:CHF|Fr\.|zł|Kč|Ft|kr|Kr|KR|[A-Z]{3}|[€£¥￥₩₹฿₫₺₱₪₴₦₡₲\$]))?',
  );

  /// Parses OCR text lines into structured [ScannedPriceItem] entries.
  static ScanAnalysisResult parseOcrLines(
    List<OcrTextLine> lines, {
    required List<String> selectedCurrencies,
    String? lockedSourceCurrency,
    String? locationCurrency,
    int imageWidth = 1,
    int imageHeight = 1,
  }) {
    final fullContextText = lines.map((l) => l.text).join('\n');
    final contextHintCurrency = lockedSourceCurrency ??
        inferExplicitContextualCurrency(fullContextText);

    final List<ScannedPriceItem> extracted = [];
    int itemCounter = 0;

    for (var i = 0; i < lines.length; i++) {
      final rawLine = lines[i].text.trim();
      if (rawLine.isEmpty) continue;
      if (_noiseLinePattern.hasMatch(rawLine)) continue;

      final lineItems = _parseSingleLine(
        rawLine,
        boundingBox: lines[i].boundingBox,
        selectedCurrencies: selectedCurrencies,
        lockedSourceCurrency: lockedSourceCurrency,
        locationCurrency: locationCurrency,
        contextHintCurrency: contextHintCurrency,
        startIndex: itemCounter,
      );

      if (lineItems.isNotEmpty) {
        extracted.addAll(lineItems);
        itemCounter += lineItems.length;
      }
    }

    final resolvedCurrency = lockedSourceCurrency ??
        extracted
            .map((e) => e.detectedCurrencyCode)
            .whereType<String>()
            .firstOrNull ??
        contextHintCurrency ??
        locationCurrency ??
        (selectedCurrencies.isNotEmpty ? selectedCurrencies.first : 'USD');

    return ScanAnalysisResult(
      items: extracted,
      inferredCurrencyCode: resolvedCurrency,
      inferenceReason: lockedSourceCurrency != null
          ? 'Manual selection'
          : (contextHintCurrency != null
              ? 'Detected from symbol'
              : (locationCurrency != null ? 'Detected from location' : null)),
      tierUsed: AiScannerTier.onDeviceOcr,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
  }

  static List<ScannedPriceItem> _parseSingleLine(
    String line, {
    required NormalizedRect? boundingBox,
    required List<String> selectedCurrencies,
    required String? lockedSourceCurrency,
    required String? locationCurrency,
    required String? contextHintCurrency,
    required int startIndex,
  }) {
    final matches = _priceCandidateRegex.allMatches(line).toList();
    if (matches.isEmpty) return const [];

    final List<ScannedPriceItem> results = [];

    for (var idx = 0; idx < matches.length; idx++) {
      final m = matches[idx];
      final prefixRaw = m.namedGroup('prefix')?.trim();
      final numberRaw = m.namedGroup('number') ?? '';
      final swissRaw = m.namedGroup('swiss');
      final kSuffix = m.namedGroup('kSuffix');
      final suffixRaw = m.namedGroup('suffix')?.trim();

      final before = line.substring(0, m.start);
      final trailing = line.substring(m.end);

      final symbolToken =
          _pickValidSymbol(prefixRaw) ?? _pickValidSymbol(suffixRaw);
      final hasExplicitCurrencyMarker =
          symbolToken != null || swissRaw != null || kSuffix != null;

      // Reject units like "550 kcal", "350 ml", "15%", "24h", "500g"
      if (!hasExplicitCurrencyMarker && _unitNoiseSuffix.hasMatch(trailing)) {
        continue;
      }

      // Reject phone/date/ratio fragments glued with hyphens, slashes, colons, or plus
      if (m.start > 0) {
        final prevChar = line[m.start - 1];
        if (prevChar == '-' ||
            prevChar == '/' ||
            prevChar == ':' ||
            prevChar == '+') {
          if (prefixRaw == null) continue;
        }
      }
      if (trailing.startsWith('-') ||
          trailing.startsWith('/') ||
          trailing.startsWith(':')) {
        if (swissRaw == null) continue;
      }

      // Reject street numbers, item indexes, phone prefixes, copyright years, etc.
      if (!hasExplicitCurrencyMarker && _noisePrefixPattern.hasMatch(before)) {
        continue;
      }

      // Reject bare 4-digit years like "2024" or "1998" when there is no currency marker
      if (!hasExplicitCurrencyMarker &&
          RegExp(r'^(19|20)\d{2}$').hasMatch(numberRaw) &&
          line.trim() != numberRaw) {
        continue;
      }

      final hasDecimalOrSeparator =
          numberRaw.contains('.') || numberRaw.contains(',') || swissRaw != null;

      // Reject bare integers embedded in the middle of prose sentences (e.g. "Abierto 24 horas al dia")
      if (!hasExplicitCurrencyMarker && !hasDecimalOrSeparator) {
        final trailingWord = trailing.trim();
        if (trailingWord.isNotEmpty &&
            RegExp(r'^[A-Za-zÀ-ÿ]').hasMatch(trailingWord)) {
          continue;
        }
      }

      final resolvedCode = lockedSourceCurrency ??
          _resolveCurrencySymbol(
            symbolToken,
            numberRaw: numberRaw,
            selectedCurrencies: selectedCurrencies,
            locationCurrency: locationCurrency,
            contextHintCurrency: contextHintCurrency,
          );

      final effectiveCurrency =
          resolvedCode ?? contextHintCurrency ?? locationCurrency;

      final parsedAmount = parseRegionalNumber(
        numberRaw,
        currencyCode: effectiveCurrency,
        hasKMultiplier: kSuffix != null,
      );

      if (parsedAmount == null || parsedAmount <= 0) continue;

      // Reject bare single-digit integers (like "1.", "2", table numbers) unless
      // accompanied by a currency symbol, decimal, k-suffix, or standalone tag.
      if (!hasExplicitCurrencyMarker &&
          !hasDecimalOrSeparator &&
          parsedAmount < 10 &&
          line.trim() != numberRaw) {
        continue;
      }

      final isInflated = effectiveCurrency != null &&
          inflatedCurrencies.contains(effectiveCurrency);
      final isWholeSmallNumber = kSuffix == null &&
          parsedAmount == parsedAmount.floorToDouble() &&
          parsedAmount >= 1 &&
          parsedAmount < 1000;

      results.add(
        ScannedPriceItem(
          id: 'scan_${startIndex + results.length}',
          rawText: m.group(0)!.trim(),
          itemLabel: null,
          normalizedAmount: parsedAmount,
          detectedCurrencyCode: resolvedCode,
          rawCurrencySymbol: symbolToken ?? (swissRaw != null ? 'CHF' : null),
          boundingBox: boundingBox,
          isShorthandMultiplied: kSuffix != null,
          canToggleThousandsShorthand: isInflated && isWholeSmallNumber,
        ),
      );
    }

    return results;
  }

  /// Parses numbers written with US, European, Swiss, or Latin American/Asian
  /// thousands/decimal conventions (e.g. `1.350`, `18.000`, `12,50`, `1,299.99`, `18k`).
  static double? parseRegionalNumber(
    String rawNumber, {
    String? currencyCode,
    bool hasKMultiplier = false,
  }) {
    final String cleaned = rawNumber.trim().replaceAll(RegExp(r'\s+'), '');
    if (cleaned.isEmpty) return null;

    final hasDot = cleaned.contains('.');
    final hasComma = cleaned.contains(',');
    final normalizedCurrency = currencyCode?.trim().toUpperCase();
    final isDotThreeDecimal = normalizedCurrency != null &&
        threeDecimalCurrencies.contains(normalizedCurrency);
    final isCommaThreeDecimal = normalizedCurrency != null &&
        _commaThreeDecimalCurrencies.contains(normalizedCurrency);

    String normalized;

    if (hasDot && hasComma) {
      // Both separators present: whichever appears LAST is the decimal separator!
      final lastDot = cleaned.lastIndexOf('.');
      final lastComma = cleaned.lastIndexOf(',');
      if (lastDot > lastComma) {
        normalized = cleaned.replaceAll(',', '');
      } else {
        normalized = cleaned.replaceAll('.', '').replaceAll(',', '.');
      }
    } else if (hasComma) {
      final parts = cleaned.split(',');
      if (parts.length > 2) {
        final last = parts.last;
        final middleAllThree =
            parts.sublist(1, parts.length - 1).every((p) => p.length == 3);
        // Handle OCR dot->comma misreads such as "1,350,00" -> "1350.00"
        if (middleAllThree && (last.length == 1 || last.length == 2)) {
          normalized = '${parts.sublist(0, parts.length - 1).join()}.$last';
        } else {
          normalized = cleaned.replaceAll(',', '');
        }
      } else {
        final intPart = parts[0];
        final frac = parts[1];
        if (frac.length == 3 &&
            intPart != '0' &&
            intPart.length <= 3 &&
            !hasKMultiplier &&
            !isCommaThreeDecimal) {
          normalized = cleaned.replaceAll(',', '');
        } else {
          normalized = '$intPart.$frac';
        }
      }
    } else if (hasDot) {
      final parts = cleaned.split('.');
      if (parts.length > 2) {
        final last = parts.last;
        final middleAllThree =
            parts.sublist(1, parts.length - 1).every((p) => p.length == 3);
        // Handle OCR comma->dot misreads such as "1.350.00" -> "1350.00"
        if (middleAllThree && (last.length == 1 || last.length == 2)) {
          normalized = '${parts.sublist(0, parts.length - 1).join()}.$last';
        } else {
          normalized = cleaned.replaceAll('.', '');
        }
      } else {
        final intPart = parts[0];
        final frac = parts[1];
        // A dot followed by 3 digits (e.g. "$1.350", "$1.300", "28.000") is a
        // thousands separator in virtually all currencies except 3-decimal
        // currencies (BHD/JOD/KWD/LYD/OMR/TND) and leading-zero decimals (0.350).
        if (frac.length == 3 &&
            intPart != '0' &&
            intPart.length <= 3 &&
            !hasKMultiplier &&
            !isDotThreeDecimal) {
          normalized = cleaned.replaceAll('.', '');
        } else {
          normalized = cleaned;
        }
      }
    } else {
      normalized = cleaned;
    }

    final value = double.tryParse(normalized);
    if (value == null) return null;

    return hasKMultiplier ? value * 1000.0 : value;
  }

  /// Extracts and parses the numeric value from a single raw price token
  /// (e.g. `"$1.350"`, `"RD$1,250.00"`, `"18k"`, `"CHF 34.-"`).
  static double? parseSingleAmount(
    String rawText, {
    String? currencyCode,
  }) {
    final m = _priceCandidateRegex.firstMatch(rawText.trim());
    if (m == null) return null;
    final numberRaw = m.namedGroup('number') ?? '';
    final kSuffix = m.namedGroup('kSuffix');
    return parseRegionalNumber(
      numberRaw,
      currencyCode: currencyCode,
      hasKMultiplier: kSuffix != null,
    );
  }

  /// Cross-checks an on-device LLM's [aiAmount] against deterministic regional
  /// number parsing of [rawText] so models cannot misread dot-thousands like
  /// `"$1.350"` as `1.35`.
  static double reconcileAiAmount({
    required String rawText,
    required double aiAmount,
    String? currencyCode,
    bool isShorthandMultiplied = false,
  }) {
    if (isShorthandMultiplied) return aiAmount;
    final parsed = parseSingleAmount(rawText, currencyCode: currencyCode);
    if (parsed != null && parsed > 0) {
      return parsed;
    }
    return aiAmount;
  }

  static String? _pickValidSymbol(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (unambiguousSymbols.containsKey(raw)) return raw;
    if (ambiguousSymbols.containsKey(raw)) return raw;
    final upper = raw.toUpperCase();
    if (knownIsoCodes.contains(upper)) return upper;
    return null;
  }

  static String? _resolveCurrencySymbol(
    String? symbolToken, {
    required String numberRaw,
    required List<String> selectedCurrencies,
    required String? locationCurrency,
    required String? contextHintCurrency,
  }) {
    if (symbolToken == null) return null;

    if (unambiguousSymbols.containsKey(symbolToken)) {
      return unambiguousSymbols[symbolToken];
    }

    final upper = symbolToken.toUpperCase();
    if (knownIsoCodes.contains(upper)) {
      return upper;
    }

    if (ambiguousSymbols.containsKey(symbolToken)) {
      final candidates = ambiguousSymbols[symbolToken]!;

      // 1. Explicit unambiguous currency mentioned on the same sign/menu
      if (contextHintCurrency != null &&
          candidates.contains(contextHintCurrency)) {
        return contextHintCurrency;
      }

      // 2. Physical location currency (e.g. DOP in Dominican Republic for "$")
      if (locationCurrency != null && candidates.contains(locationCurrency)) {
        return locationCurrency;
      }

      // 3. Only when location is unknown, dot-thousands like "$18.000" suggests COP/CLP/ARS
      if (locationCurrency == null &&
          symbolToken == '\$' &&
          RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(numberRaw)) {
        for (final latam in const ['COP', 'CLP', 'ARS']) {
          if (selectedCurrencies.contains(latam)) return latam;
        }
        return 'COP';
      }

      // 4. Prefer a candidate that the user already has in their selected currencies
      for (final selected in selectedCurrencies) {
        if (candidates.contains(selected)) {
          return selected;
        }
      }

      return candidates.first;
    }

    return null;
  }

  static String? inferExplicitContextualCurrency(String fullText) {
    // 1. Check for explicit ISO code mentions anywhere on the sign
    for (final code in knownIsoCodes) {
      if (RegExp('\\b$code\\b').hasMatch(fullText)) {
        return code;
      }
    }

    // 2. Check unambiguous symbols anywhere in the block (e.g., RD$, US$, €, £)
    for (final entry in unambiguousSymbols.entries) {
      if (fullText.contains(entry.key)) {
        return entry.value;
      }
    }

    // 3. Unambiguous single-country scripts
    if (RegExp(r'[\uAC00-\uD7AF]').hasMatch(fullText)) return 'KRW';
    if (RegExp(r'[\u3040-\u30FF]').hasMatch(fullText)) return 'JPY';
    if (RegExp(r'[\u0E00-\u0E7F]').hasMatch(fullText)) return 'THB';

    return null;
  }
}
