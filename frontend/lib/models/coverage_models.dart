class CoverageCell {
  final double lat;
  final double lng;
  final int count;

  CoverageCell({
    required this.lat,
    required this.lng,
    required this.count,
  });

  factory CoverageCell.fromJson(Map<String, dynamic> json) {
    return CoverageCell(
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      count: json['count'] as int? ?? 0,
    );
  }
}

class CoverageResponse {
  final List<CoverageCell> cells;
  final double cellSize;
  final int totalCells;

  CoverageResponse({
    required this.cells,
    required this.cellSize,
    required this.totalCells,
  });

  factory CoverageResponse.fromJson(Map<String, dynamic> json) {
    return CoverageResponse(
      cells: (json['cells'] as List<dynamic>?)
              ?.map((e) => CoverageCell.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      cellSize: (json['cell_size'] as num?)?.toDouble() ?? 0.0,
      totalCells: json['total_cells'] as int? ?? 0,
    );
  }
}
