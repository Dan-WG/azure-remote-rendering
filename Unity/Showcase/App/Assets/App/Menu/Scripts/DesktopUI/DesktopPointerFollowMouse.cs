using Microsoft.MixedReality.Toolkit.Utilities;
using UnityEngine;

public class DesktopPointerFollowMouse : MonoBehaviour
{
    public float depthOffset;
    public Vector3 offset;

    private void Update()
    {
        // Follow mouse
        var mousePosition = Input.mousePosition;
        mousePosition.z = depthOffset;
        mousePosition = CameraCache.Main.ScreenToWorldPoint(mousePosition);
        transform.rotation = CameraCache.Main.transform.rotation;
        transform.position = mousePosition + (transform.rotation * offset);
    }
}
