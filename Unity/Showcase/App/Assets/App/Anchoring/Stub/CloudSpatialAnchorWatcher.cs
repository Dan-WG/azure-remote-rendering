#if !AZURE_SPATIAL_ANCHORS_ENABLED
using System;

namespace Microsoft.Azure.SpatialAnchors.Stub
{
    public class CloudSpatialAnchorWatcher
    {
        internal void Stop()
        {
            throw new NotImplementedException();
        }
    }
}
#endif
