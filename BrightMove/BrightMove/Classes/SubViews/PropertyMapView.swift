import SwiftUI
import AppKit
import MapKit
import RightmoveKit

/// SwiftUI wrapper around `MKMapView`, used as the map renderer for search
/// results. It's a pure view of the supplied properties — it never starts a
/// search itself. Clustering and annotation reuse are MapKit's; this type just
/// diffs annotations in/out, frames the camera on request, and reports taps.
struct PropertyMapView: NSViewRepresentable {
    /// Mappable search results (caller has already filtered out coordinate-less ones).
    let properties: [SearchProperty]
    let pinnedIDs: Set<Int>
    /// Changes to this value request a camera re-fit to the current pins.
    let fitToken: Int
    /// Used to centre the map when there are no mappable results.
    let fallbackCenter: CLLocationCoordinate2D?
    /// Tapped "View details" in a callout → the property's id.
    let onSelect: (Int) -> Void
    /// Pin toggle from a callout → the property's id.
    let onTogglePin: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.register(PriceCapsuleAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: PriceCapsuleAnnotationView.reuseID)
        map.register(PropertyClusterAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        context.coordinator.mapView = map
        context.coordinator.sync(animated: false)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(animated: true)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PropertyMapView
        weak var mapView: MKMapView?

        private var annotationsByID: [Int: PropertyAnnotation] = [:]
        private var boundingOverlay: MKPolygon?
        /// Popover used to disambiguate a cluster whose members sit on the exact
        /// same coordinate (zooming can't separate them).
        private var disambiguationPopover: NSPopover?
        private var lastFitToken: Int = .min
        /// True once the user has panned/zoomed the current result set, which
        /// suppresses auto-fit until the next explicit fit request (new search).
        private var userMovedMap = false
        /// Set while we move the camera ourselves, so the region-change delegate
        /// doesn't mistake our move for a user gesture.
        private var isProgrammaticMove = false

        init(parent: PropertyMapView) {
            self.parent = parent
        }

        /// Reconcile the map's annotations and camera with `parent`.
        func sync(animated: Bool) {
            guard let mapView else { return }

            let desired = parent.properties
            let desiredIDs = Set(desired.compactMap(\.propertyID))
            let existingIDs = Set(annotationsByID.keys)

            // Remove annotations no longer in the result set.
            let removedIDs = existingIDs.subtracting(desiredIDs)
            if !removedIDs.isEmpty {
                let toRemove = removedIDs.compactMap { annotationsByID[$0] }
                mapView.removeAnnotations(toRemove)
                removedIDs.forEach { annotationsByID[$0] = nil }
            }

            // Add new annotations.
            var added: [PropertyAnnotation] = []
            for property in desired {
                guard let id = property.propertyID else { continue }
                if annotationsByID[id] == nil {
                    if let annot = PropertyAnnotation(search: property,
                                                      isPinned: parent.pinnedIDs.contains(id)) {
                        annotationsByID[id] = annot
                        added.append(annot)
                    }
                } else if let annot = annotationsByID[id] {
                    // Refresh pinned state on a property already on the map.
                    let nowPinned = parent.pinnedIDs.contains(id)
                    if annot.isPinned != nowPinned {
                        annot.isPinned = nowPinned
                        if let view = mapView.view(for: annot) {
                            view.annotation = annot   // retrigger configure()
                        }
                    }
                }
            }
            if !added.isEmpty { mapView.addAnnotations(added) }

            // Keep the bounding-box overlay in step with the current pins.
            updateBoundingOverlay(on: mapView)

            // Camera framing: honour an explicit fit request unless the user has
            // taken control of the map for this result set.
            if parent.fitToken != lastFitToken {
                lastFitToken = parent.fitToken
                userMovedMap = false
                fit(animated: animated)
            } else if !userMovedMap && !added.isEmpty {
                // New pins streamed in and the user hasn't moved the map yet —
                // keep them in frame.
                fit(animated: animated)
            }
        }

        private func fit(animated: Bool) {
            guard let mapView else { return }
            let annotations = Array(annotationsByID.values)
            isProgrammaticMove = true
            if annotations.isEmpty {
                if let center = parent.fallbackCenter {
                    let region = MKCoordinateRegion(
                        center: center,
                        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))
                    mapView.setRegion(region, animated: animated)
                } else {
                    isProgrammaticMove = false
                }
            } else {
                mapView.showAnnotations(annotations, animated: animated)
            }
        }

        /// Recompute the rectangle enclosing all current pins and swap it in as
        /// a single overlay. Needs at least two distinct points to be meaningful.
        private func updateBoundingOverlay(on mapView: MKMapView) {
            if let existing = boundingOverlay {
                mapView.removeOverlay(existing)
                boundingOverlay = nil
            }

            let coords = annotationsByID.values.map(\.coordinate)
            guard coords.count >= 2 else { return }

            let lats = coords.map(\.latitude)
            let lngs = coords.map(\.longitude)
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLng = lngs.min(), let maxLng = lngs.max(),
                  minLat != maxLat || minLng != maxLng else { return }

            let corners = [
                CLLocationCoordinate2D(latitude: maxLat, longitude: minLng),
                CLLocationCoordinate2D(latitude: maxLat, longitude: maxLng),
                CLLocationCoordinate2D(latitude: minLat, longitude: maxLng),
                CLLocationCoordinate2D(latitude: minLat, longitude: minLng),
            ]
            let polygon = MKPolygon(coordinates: corners, count: corners.count)
            mapView.addOverlay(polygon, level: .aboveRoads)
            boundingOverlay = polygon
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? MKPolygon else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.strokeColor = .controlAccentColor
            renderer.lineWidth = 1.5
            renderer.lineDashPattern = [4, 4]
            renderer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.06)
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: annotation)
                return view
            }
            guard let property = annotation as? PropertyAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: PriceCapsuleAnnotationView.reuseID,
                for: property)
            view.annotation = property
            view.detailCalloutAccessoryView = makeCallout(for: property)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                // If the members are stacked on (nearly) the same coordinate,
                // zooming will never break them apart — offer a picker instead.
                if membersAreCoincident(cluster) {
                    presentDisambiguation(for: cluster, from: view, in: mapView)
                } else {
                    zoom(to: cluster, in: mapView)
                }
            } else if let property = view.annotation as? PropertyAnnotation {
                // Rebuild the callout so its closures capture the current state.
                view.detailCalloutAccessoryView = makeCallout(for: property)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if isProgrammaticMove {
                isProgrammaticMove = false
            } else {
                userMovedMap = true
            }
        }

        // MARK: Helpers

        private func makeCallout(for property: PropertyAnnotation) -> NSView {
            let card = MapCalloutCard(
                annotation: property,
                isPinned: parent.pinnedIDs.contains(property.propertyID),
                onViewDetails: { [weak self] in self?.parent.onSelect(property.propertyID) },
                onTogglePin: { [weak self] in self?.parent.onTogglePin(property.propertyID) }
            )
            let hosting = NSHostingView(rootView: card)
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            return hosting
        }

        private func zoom(to cluster: MKClusterAnnotation, in mapView: MKMapView) {
            let rects = cluster.memberAnnotations.map { annot -> MKMapRect in
                let point = MKMapPoint(annot.coordinate)
                return MKMapRect(x: point.x, y: point.y, width: 0, height: 0)
            }
            guard let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else { return }
            isProgrammaticMove = true
            let padding = NSEdgeInsets(top: 60, left: 60, bottom: 60, right: 60)
            mapView.setVisibleMapRect(union, edgePadding: padding, animated: true)
        }

        /// True when every member of the cluster sits within a few metres of the
        /// first — i.e. zooming further can't separate them, so we must offer a
        /// picker rather than try to zoom in.
        private func membersAreCoincident(_ cluster: MKClusterAnnotation) -> Bool {
            let coords = cluster.memberAnnotations.map(\.coordinate)
            guard let first = coords.first else { return false }
            let reference = CLLocation(latitude: first.latitude, longitude: first.longitude)
            for coord in coords.dropFirst() {
                let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                // ~8 m: closer than this and the price capsules overlap at any
                // zoom level, so MapKit keeps them clustered indefinitely.
                if reference.distance(from: location) > 8 { return false }
            }
            return true
        }

        /// Show a popover listing the coincident properties so the user can pick
        /// one even though they share a coordinate.
        private func presentDisambiguation(for cluster: MKClusterAnnotation,
                                           from view: MKAnnotationView,
                                           in mapView: MKMapView) {
            let members = cluster.memberAnnotations.compactMap { $0 as? PropertyAnnotation }
            guard !members.isEmpty else { return }

            disambiguationPopover?.close()

            let list = CoincidentPropertiesList(
                properties: members,
                pinnedIDs: parent.pinnedIDs,
                onSelect: { [weak self] id in
                    self?.disambiguationPopover?.close()
                    self?.parent.onSelect(id)
                },
                onTogglePin: { [weak self] id in
                    self?.parent.onTogglePin(id)
                }
            )

            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: list)
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            disambiguationPopover = popover
        }
    }
}
