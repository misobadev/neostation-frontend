/// Shared geometry and text sizing for the game List view.
class GameListSize {
  static const values = ['S', 'M', 'L', 'XL'];

  static int index(String value) {
    final result = values.indexOf(value);
    return result < 0 ? 0 : result;
  }

  static double getScale(String value) =>
      const [1.0, 13 / 11, 15 / 11, 17 / 11][index(value)];

  static double getFontSize(String value) => 11 * getScale(value);
  static double getRowHeight(String value) =>
      const [26.0, 30.0, 34.0, 38.0][index(value)];
  static double getPanelWidth(String value) =>
      const [200.0, 215.0, 230.0, 245.0][index(value)];
}
