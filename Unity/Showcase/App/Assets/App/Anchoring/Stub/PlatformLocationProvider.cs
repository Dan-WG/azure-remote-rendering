#if !AZURE_SPATIAL_ANCHORS_ENABLED
namespace Microsoft.Azure.SpatialAnchors.Stub
{
    public class PlatformLocationProvider
    {
        public SensorCapabilities Sensors { get; internal set; }
    }
}
#endif

