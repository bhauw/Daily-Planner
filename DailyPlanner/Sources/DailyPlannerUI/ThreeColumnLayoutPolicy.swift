import CoreGraphics

public enum ThreeColumnLayoutPolicy {
    public static func widths(total: CGFloat) -> (left: CGFloat, center: CGFloat, right: CGFloat) {
        let side = max(260, total * 0.27)
        return (side, total - (side * 2), side)
    }
}
