class BoundingBox {
  final double xmin;
  final double ymin;
  final double xmax;
  final double ymax;

  BoundingBox({
    required this.xmin,
    required this.ymin,
    required this.xmax,
    required this.ymax,
  });

  factory BoundingBox.fromJson(List<dynamic> json) {
    return BoundingBox(
      xmin: (json[0] as num).toDouble(),
      ymin: (json[1] as num).toDouble(),
      xmax: (json[2] as num).toDouble(),
      ymax: (json[3] as num).toDouble(),
    );
  }
}

class AnalyzeResult {
  final String label;
  final double confidence;
  final BoundingBox bbox;

  AnalyzeResult({
    required this.label,
    required this.confidence,
    required this.bbox,
  });

  factory AnalyzeResult.fromJson(Map<String, dynamic> json) {
    return AnalyzeResult(
      label: json['label'] as String? ?? 'unknown',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      bbox: BoundingBox.fromJson(json['bbox'] as List<dynamic>),
    );
  }
}

class AnalyzeResponse {
  final List<AnalyzeResult> results;

  AnalyzeResponse({required this.results});

  factory AnalyzeResponse.fromJson(Map<String, dynamic> json) {
    var list = json['results'] as List<dynamic>? ?? [];
    List<AnalyzeResult> resultsList = list.map((i) => AnalyzeResult.fromJson(i as Map<String, dynamic>)).toList();
    
    return AnalyzeResponse(results: resultsList);
  }
}
