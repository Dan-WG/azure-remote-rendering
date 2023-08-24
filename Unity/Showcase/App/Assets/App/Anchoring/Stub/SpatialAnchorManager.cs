#if !AZURE_SPATIAL_ANCHORS_ENABLED
using System;
using System.Threading.Tasks;

using UnityEngine;

namespace Microsoft.Azure.SpatialAnchors.Stub
{
    public enum AuthenticationMode
    {
        ApiKey,
        AAD
    }

    public class SpatialAnchorManager : MonoBehaviour
    {
        public string SpatialAnchorsAccountId { get; internal set; }
        public string SpatialAnchorsAccountKey { get; internal set; }
        public string SpatialAnchorsAccountDomain { get; internal set; }
        public AuthenticationMode AuthenticationMode { get; internal set; }
        public CloudSpatialAnchorSession Session { get; internal set; }
        public bool IsSessionStarted { get; internal set; }

        public Action<object, EventArgs> SessionCreated { get; internal set; }
        public Action<object, EventArgs> SessionChanged { get; internal set; }
        public Action<object, AnchorLocatedEventArgs> AnchorLocated { get; internal set; }

        internal Task StartSessionAsync()
        {
            throw new NotImplementedException();
        }

        internal void StopSession()
        {
            throw new NotImplementedException();
        }
    }
}
#endif
