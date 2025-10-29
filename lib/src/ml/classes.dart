class SegClasses {
  // Adjust to your model's class order
  static const List<String> names = [
    'window',
    'sofa',
    'chair',
    'table',
    'person',
    'plant',
    'tv',
    'curtain'
  ];

  static int idOf(String name) => names.indexOf(name);

  static const String window = 'window';
  static const List<String> occluderNames = [
    'sofa',
    'chair',
    'table',
    'person',
    'plant',
    'tv'
  ];

  static List<int> get occluderIds =>
      occluderNames.map(idOf).where((i) => i >= 0).toList();
  static int get windowId => idOf(window);
  static int get numClasses => names.length;
}
