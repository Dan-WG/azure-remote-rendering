#if !AZURE_SPATIAL_ANCHORS_ENABLED
namespace Microsoft.Azure.SpatialAnchors.Stub
{
    public class NearDeviceCriteria
    {
        public float DistanceInMeters { get; internal set; }
        public int MaxResultCount { get; internal set; }
    }
}
#endif
