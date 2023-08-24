#if !AZURE_SPATIAL_ANCHORS_ENABLED
using System;
using System.Collections.Generic;

using UnityEngine;

namespace Microsoft.Azure.SpatialAnchors.Stub
{
    public class CloudSpatialAnchor
    {
        public IDictionary<string, string> AppProperties { get; internal set; }
        public DateTimeOffset Expiration { get; internal set; }
        public string Identifier { get; internal set; }

        internal Pose GetPose()
        {
            throw new NotImplementedException();
        }
    }
}
#endif
