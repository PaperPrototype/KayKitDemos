Simple camera/input focus system similar to Cinemachine but for input + camera combined.

## Usage
```cs
// <summary>Attach this to a game object that will serve as a virtual camera.</summary>
public class VirtualFollowCharacterCamera : VirtualFocus {

  // TODO use input actions map
  // public AssetRef<InputActionsMap> inputActions;

  public AssetRef<PlayerController> playerController;
  public AssetRef<Transform> lookAtTarget;
  public AssetRef<Transform> followTarget;
  public Float3 offset = new Float3(10, 10, 10);
  public float metersPerSecond = 10;

  public override void Update() {
    if (Input.GetKey(KeyCode.Number1)) {
      Focus();
    }

    this.Transform.Position = followTarget.Position + offset;
    this.Transform.LookAt(lookAtTarget);

    Float3 movement;
    if (Input.GetKey(KeyCode.W)) {
      movement += Float3.UnitZ * Time.DeltaTime * metersPerSecond;
    } else if (Input.GetKey(KeyCode.S)) {
      movement -= Float3.UnitZ * Time.DeltaTime * metersPerSecond;
    } else if (Input.GetKey(KeyCode.A)) {
      movement += Float3.UnitX * Time.DeltaTime * metersPerSecond;
    } else if (Input.GetKey(KeyCode.D)) {
      movement -= Float3.UnitX * Time.DeltaTime * metersPerSecond;
    }

    playerController.Move(movement);
  }
}
```

## Concept
```cs
// <summary>Attach this to the scene camera.</summary>
public abstract class VirtualFocus : MonoBehavior {
  public string CameraId = "virtual";
  public float FieldOfView = 60f;
  public float NearClipPlane = 0.1f;
  public float FarClipPlane = 100f;

  protected FocusBrain _brain;

  public virtual string GetIdName();

  public override void OnCreate() {
    _brain = this.Scene.FindComponentOfType<FocusBrain>();
    _brain.Add(CameraId, this);
  }

  public override void OnDestroy() {
    _brain.Remove(CameraId, this);
  }

  public void Focus() {
    _brain.Blur();
    _brain.Focus(CameraId);
  }

  // Draw debug as if it was a camera
}
```