import Foundation

#if canImport(CoreLocation)
import CoreLocation

public enum ReverseGeocoder {
    /// Sends the coordinate to Apple's geocoder. The photo itself is not uploaded.
    public static func placeName(latitude: Double, longitude: Double) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        return PlaceName.join(
            locality: mark.locality ?? mark.subLocality ?? mark.name,
            region: mark.administrativeArea,
            country: mark.country
        )
    }
}
#endif
