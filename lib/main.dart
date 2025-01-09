import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:csv/csv.dart';
import 'package:split_view/split_view.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget
class MyApp extends StatelessWidget {
  const MyApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CSV Viewer',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSwatch(primarySwatch: Colors.grey),
      ),
      home: const MyHomePage(),
    );
  }
}

/// The main page with a top/bottom split.
class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

/// This example:
/// - Reads CSV with columns: [Item, Description, UM, Material, Labor, Equipment, Total].
/// - If UM == 'PCT', parse 'Total' as a fraction (e.g. '5' => 0.05).
/// - If UM != 'PCT' and there's no material/labor/equipment, we do lineTotal = csvTotal * quantity.
/// - Otherwise lineTotal = (mat+lab+eqp) * quantity.
/// - Preserves the header row so top table columns remain.
/// - Expands top SplitView to 60% by default so there's less overflow.
class _MyHomePageState extends State<MyHomePage> {
  late List<List<dynamic>> _lines;         // Entire CSV (row 0 is headers)
  late List<List<dynamic>> _filteredLines; // Filtered CSV, preserving row 0
  late List<String> _headers;              // The header row as strings

  // Indices for each required column
  int _idxItem = -1;
  int _idxDescription = -1;
  int _idxUM = -1;
  int _idxMaterial = -1;
  int _idxLabor = -1;
  int _idxEquipment = -1;
  int _idxTotal = -1;

  late CSVDataSource _csvDataSource;       // For top PaginatedDataTable

  final List<AddedItem> _bottomItems = []; // The "collection" at bottom

  bool _isLoading = true;
  String _errorMessage = '';

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCsvData();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  /// Load the CSV in a background isolate
  Future<void> _loadCsvData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final lines = await compute(_parseCsvInIsolate, 'assets/mydata.csv');
      if (lines.isEmpty) throw 'CSV is empty!';

      _lines = lines;

      // The header row
      final rawHeaders = _lines.first;
      _headers =
          rawHeaders.map((cell) => cell.toString().trim()).toList(growable: false);

      // Find indices for required columns
      _idxItem = _headers.indexOf('Item');
      _idxDescription = _headers.indexOf('Description');
      _idxUM = _headers.indexOf('UM');
      _idxMaterial = _headers.indexOf('Material');
      _idxLabor = _headers.indexOf('Labor');
      _idxEquipment = _headers.indexOf('Equipment');
      _idxTotal = _headers.indexOf('Total');

      if ([_idxItem, _idxDescription, _idxUM, _idxMaterial, _idxLabor, _idxEquipment, _idxTotal]
          .contains(-1)) {
        throw 'Missing one of [Item,Description,UM,Material,Labor,Equipment,Total] in CSV headers.';
      }

      // No search => entire CSV
      _filteredLines = List.from(_lines);

      _csvDataSource = CSVDataSource(
        lines: _filteredLines,
        onAddSingle: _addSingleRowToBottom,
      );
    } catch (e) {
      _errorMessage = 'Error loading CSV: $e';
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  static Future<List<List<dynamic>>> _parseCsvInIsolate(String assetPath) async {
    final csvString = await rootBundle.loadString(assetPath);
    return const CsvToListConverter().convert(csvString);
  }

  void _onSearchChanged() {
    _filterData(_searchController.text);
  }

  /// Keep row 0 (headers) always. Filter the rest if query
  void _filterData(String query) {
    setState(() {
      final headerRow = _lines.first;
      final dataRows = _lines.skip(1);
      if (query.trim().isEmpty) {
        _filteredLines = List.from(_lines);
      } else {
        final lower = query.toLowerCase();
        final filteredData = dataRows.where((row) {
          return row.any((cell) => cell.toString().toLowerCase().contains(lower));
        }).toList();
        _filteredLines = [headerRow, ...filteredData];
      }
      _csvDataSource.updateData(_filteredLines);
    });
  }

  /// "Add Selected" button
  void _addSelectedRows() {
    final selectedRows = _csvDataSource.getSelectedRows();
    for (final row in selectedRows) {
      _addSingleRowToBottom(row);
    }
    _csvDataSource.clearSelection();
  }

  /// Add a single row from top table to bottom
  /// - If UM == 'PCT', parse "Total" as fraction.
  /// - If UM != 'PCT', if material+labor+equip > 0 => lineTotal = sum * qty.
  ///   Otherwise => lineTotal = csvTotal * qty.
  void _addSingleRowToBottom(List<dynamic> row) {
    if (row.length < _headers.length) return;

    final umStr = row[_idxUM]?.toString() ?? '';
    final mat = _toDouble(row[_idxMaterial]);
    final lab = _toDouble(row[_idxLabor]);
    final eqp = _toDouble(row[_idxEquipment]);
    double totalVal;

    if (umStr.toUpperCase() == 'PCT') {
      totalVal = _parsePercentage(row[_idxTotal]);
    } else {
      totalVal = _toDouble(row[_idxTotal]);
      // If total is 0, we still store it in csvTotal. We'll do the logic in get lineTotal.
    }

    final newItem = AddedItem(
      item: row[_idxItem]?.toString() ?? '',
      description: row[_idxDescription]?.toString() ?? '',
      um: umStr,
      material: mat,
      labor: lab,
      equipment: eqp,
      csvTotal: totalVal,
    );

    setState(() {
      _bottomItems.add(newItem);
    });
  }

  /// Remove '$' / ',' / '%' before parsing as fraction
  double _parsePercentage(dynamic cell) {
    if (cell == null) return 0.0;
    var s = cell.toString().toLowerCase().trim();
    s = s.replaceAll('\$', '');
    s = s.replaceAll('%', '');
    s = s.replaceAll(',', '');
    final rawVal = double.tryParse(s) ?? 0.0;
    if (rawVal > 1.0) {
      return rawVal / 100.0;
    }
    return rawVal;
  }

  /// Remove '$' / ',' from normal cost cells
  double _toDouble(dynamic val) {
    if (val == null) return 0.0;
    var s = val.toString().toLowerCase().trim();
    s = s.replaceAll('\$', '');
    s = s.replaceAll(',', '');
    // if empty => 0.0
    if (s.isEmpty) return 0.0;
    return double.tryParse(s) ?? 0.0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // White appbar
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        title: const Text('My CSV Viewer', style: TextStyle(color: Colors.black)),
        elevation: 1,
      ),
      body: Column(
        children: [
          // -- SEARCH + ADD SELECTED --
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: 'Search entire data',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _addSelectedRows,
                  child: const Text('Add Selected'),
                ),
              ],
            ),
          ),

          // -- SPLIT VIEW: top table vs bottom table --
          Expanded(
            child: SplitView(
              viewMode: SplitViewMode.Vertical,
              // Make top ~60%, bottom ~40%
              controller: SplitViewController(weights: [0.6, 0.4]),
              gripSize: 8,
              gripColor: Colors.grey.shade200,
              gripColorActive: Colors.grey.shade400,
              children: [
                _buildTopSection(),
                _buildBottomSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopSection() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage.isNotEmpty) {
      return Center(child: Text(_errorMessage));
    }
    if (_filteredLines.isEmpty || _filteredLines.first.isEmpty) {
      return const Center(child: Text('No data loaded'));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: constraints.maxWidth,
              maxWidth: constraints.maxWidth,
            ),
            child: PaginatedDataTable(
              header: Text(
                'Top CSV Data (filtered: ${_filteredLines.length - 1} rows)',
              ),
              columns: _buildTopColumns(),
              source: _csvDataSource,
              rowsPerPage: 10,
              availableRowsPerPage: const [5, 10, 20, 50],
              showCheckboxColumn: true,
            ),
          ),
        );
      },
    );
  }

  /// Build columns from the first row (header) + extra "Actions" column
  List<DataColumn> _buildTopColumns() {
    final headerRow = _filteredLines.first; 
    return [
      // For each header cell, create a DataColumn
      ...headerRow.map((cell) {
        final labelStr = cell?.toString() ?? '';
        return DataColumn(
          label: Text(
            labelStr,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      }).toList(),
      // Extra "Actions" column
      const DataColumn(
        label: Text('Actions', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    ];
  }

  Widget _buildBottomSection() {
    // The bottom is a column with:
    //   - Title
    //   - Scrollable DataTable
    //   - Aggregation Table
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: Colors.grey.shade200,
          padding: const EdgeInsets.all(8),
          child: const Text(
            'My Collection (quantity or \$ if PCT)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _buildBottomDataTable(),
          ),
        ),
        const Divider(),
        _buildAggregateSection(),
      ],
    );
  }

  Widget _buildBottomDataTable() {
    // Columns:
    // 1) Item
    // 2) Description
    // 3) UM
    // 4) Material
    // 5) Labor
    // 6) Equipment
    // 7) CSV "Total"
    // 8) Qty/PCT
    // 9) Total Material
    // 10) Total Labor
    // 11) Total Equipment
    // 12) Line Total
    final columns = <DataColumn>[
      const DataColumn(label: Text('Item')),
      const DataColumn(label: Text('Description')),
      const DataColumn(label: Text('UM')),
      const DataColumn(label: Text('Material')),
      const DataColumn(label: Text('Labor')),
      const DataColumn(label: Text('Equipment')),
      const DataColumn(label: Text('Total')),
      const DataColumn(label: Text('Qty/PCT')),
      const DataColumn(label: Text('Total Material')),
      const DataColumn(label: Text('Total Labor')),
      const DataColumn(label: Text('Total Equipment')),
      const DataColumn(label: Text('Line Total')),
    ];

    final rows = _bottomItems.map((item) {
      return DataRow(
        cells: [
          DataCell(Text(item.item)),
          DataCell(Text(item.description)),
          DataCell(Text(item.um)),
          DataCell(Text(item.material.toStringAsFixed(2))),
          DataCell(Text(item.labor.toStringAsFixed(2))),
          DataCell(Text(item.equipment.toStringAsFixed(2))),

          // If "PCT", this might be fraction. If normal, it's the actual total or fallback.
          DataCell(Text(item.csvTotal.toStringAsFixed(2))),

          // Editable quantity/dollar
          DataCell(
            SizedBox(
              width: 60,
              child: TextFormField(
                initialValue: item.quantity.toStringAsFixed(2),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (val) {
                  final parsed = double.tryParse(val) ?? 1.0;
                  setState(() {
                    item.quantity = parsed;
                  });
                },
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.all(6),
                ),
              ),
            ),
          ),

          DataCell(Text(item.totalMaterial.toStringAsFixed(2))),
          DataCell(Text(item.totalLabor.toStringAsFixed(2))),
          DataCell(Text(item.totalEquipment.toStringAsFixed(2))),
          DataCell(Text(item.lineTotal.toStringAsFixed(2))),
        ],
      );
    }).toList();

    return DataTable(columns: columns, rows: rows);
  }

  /// Summaries grouped by first 2 digits of the Item code
  Widget _buildAggregateSection() {
    final Map<String, _Agg> aggMap = {};
    for (final item in _bottomItems) {
      final code = (item.item.length >= 2)
          ? item.item.substring(0, 2)
          : item.item;
      aggMap.putIfAbsent(code, () => _Agg());
      final agg = aggMap[code]!;
      agg.material += item.totalMaterial;
      agg.labor += item.totalLabor;
      agg.equipment += item.totalEquipment;
      agg.lineTotal += item.lineTotal;
    }

    if (aggMap.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: Text('No items added yet.'),
      );
    }

    // Table: [Type, Material, Labor, Equipment, Line Total]
    final columns = <DataColumn>[
      const DataColumn(
          label: Text('Type', style: TextStyle(fontWeight: FontWeight.bold))),
      const DataColumn(
          label: Text('Material', style: TextStyle(fontWeight: FontWeight.bold))),
      const DataColumn(
          label: Text('Labor', style: TextStyle(fontWeight: FontWeight.bold))),
      const DataColumn(
          label: Text('Equipment', style: TextStyle(fontWeight: FontWeight.bold))),
      const DataColumn(
          label: Text('Line Total', style: TextStyle(fontWeight: FontWeight.bold))),
    ];

    final rows = aggMap.entries.map((e) {
      final typeCode = e.key;
      final agg = e.value;
      return DataRow(cells: [
        DataCell(Text(typeCode)),
        DataCell(Text(agg.material.toStringAsFixed(2))),
        DataCell(Text(agg.labor.toStringAsFixed(2))),
        DataCell(Text(agg.equipment.toStringAsFixed(2))),
        DataCell(Text(agg.lineTotal.toStringAsFixed(2))),
      ]);
    }).toList();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(columns: columns, rows: rows),
    );
  }
}

/// Represents one "added" item in the bottom table
class AddedItem {
  final String item;
  final String description;
  final String um;    // 'PCT' => parse differently
  final double material;
  final double labor;
  final double equipment;
  // For normal items => the CSV "Total" or leftover
  // For PCT => fraction (e.g. 5 => 0.05)
  final double csvTotal;

  double quantity = 1.0; // user-editable

  AddedItem({
    required this.item,
    required this.description,
    required this.um,
    required this.material,
    required this.labor,
    required this.equipment,
    required this.csvTotal,
  });

  double get sumMLE => material + labor + equipment;

  /// If UM == 'PCT', lineTotal = quantity * csvTotal (treat csvTotal as fraction).
  /// Else if sumMLE > 0 => lineTotal = sumMLE * quantity.
  /// Else => lineTotal = csvTotal * quantity.
  double get lineTotal {
    if (um.toUpperCase() == 'PCT') {
      return quantity * csvTotal;
    } else {
      if (sumMLE > 0) {
        return sumMLE * quantity;
      } else {
        return csvTotal * quantity;
      }
    }
  }

  // For aggregator, we only count the "Material, Labor, Equipment" if sumMLE > 0
  // Otherwise, it's a "total-only" item with no M, L, E breakdown
  double get totalMaterial => (um.toUpperCase() == 'PCT' || sumMLE == 0)
      ? 0.0
      : material * quantity;
  double get totalLabor => (um.toUpperCase() == 'PCT' || sumMLE == 0)
      ? 0.0
      : labor * quantity;
  double get totalEquipment => (um.toUpperCase() == 'PCT' || sumMLE == 0)
      ? 0.0
      : equipment * quantity;
}

/// Aggregation for summary
class _Agg {
  double material = 0.0;
  double labor = 0.0;
  double equipment = 0.0;
  double lineTotal = 0.0;
}

/// DataTableSource for the top table
class CSVDataSource extends DataTableSource {
  List<List<dynamic>> _lines = [];
  final Set<int> _selected = {};

  final void Function(List<dynamic>) onAddSingle;

  CSVDataSource({
    required List<List<dynamic>> lines,
    required this.onAddSingle,
  }) {
    updateData(lines);
  }

  void updateData(List<List<dynamic>> newLines) {
    _lines = newLines;
    _selected.clear();
    notifyListeners();
  }

  /// The data rows are everything after row 0 (headers)
  List<List<dynamic>> get _dataRows =>
      (_lines.length > 1) ? _lines.sublist(1) : [];

  List<List<dynamic>> getSelectedRows() {
    final all = _dataRows;
    return _selected.map((i) => all[i]).toList();
  }

  void clearSelection() {
    _selected.clear();
    notifyListeners();
  }

  @override
  DataRow? getRow(int index) {
    if (index >= _dataRows.length) return null;
    final row = _dataRows[index];
    final isSelected = _selected.contains(index);

    // One cell per CSV column
    final cells = row.map((cell) => DataCell(Text(cell?.toString() ?? ''))).toList();

    // Extra "Actions" cell
    cells.add(
      DataCell(
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: 'Add to bottom',
          onPressed: () {
            onAddSingle(row);
          },
        ),
      ),
    );

    return DataRow(
      selected: isSelected,
      onSelectChanged: (bool? val) {
        if (val == null) return;
        if (val) {
          _selected.add(index);
        } else {
          _selected.remove(index);
        }
        notifyListeners();
      },
      cells: cells,
    );
  }

  @override
  bool get isRowCountApproximate => false;

  @override
  int get rowCount => _dataRows.length;

  @override
  int get selectedRowCount => _selected.length;
}
