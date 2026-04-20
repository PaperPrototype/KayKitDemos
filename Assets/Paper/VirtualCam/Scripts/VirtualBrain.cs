using Prowl.Runtime;

using Prowl.Echo;
using Prowl.Runtime.Resources;
using Prowl.Vector;

public class VirtualBrain : MonoBehaviour
{
    public AssetRef<CharacterController> characterController;
    public AssetRef<GameObject> lookAtTarget;
    public AssetRef<GameObject> followTarget;
    public Float3 offset = new Float3(10, 10, 10);
    public float metersPerSecond = 10;

    public override void Update()
    {
        this.Transform.Position = followTarget.Res.Transform.Position + offset;
        
        var eyePosition = followTarget.Res.Transform.Position + offset;
        var targetTransform = Float4x4.CreateLookAt(eyePosition, lookAtTarget.Res.Transform.Position, Float3.UnitY);
        this.GameObject.Transform.Position = (Float4)targetTransform.Translation;
        this.GameObject.Transform.Rotation = Quaternion.FromMatrix(targetTransform);

        Float3 movement = Float3.Zero;
        if (Input.GetKey(KeyCode.W))
        {
            movement += Float3.UnitZ * Time.DeltaTime * metersPerSecond;
        }
        else if (Input.GetKey(KeyCode.S))
        {
            movement -= Float3.UnitZ * Time.DeltaTime * metersPerSecond;
        }
        else if (Input.GetKey(KeyCode.A))
        {
            movement += Float3.UnitX * Time.DeltaTime * metersPerSecond;
        }
        else if (Input.GetKey(KeyCode.D))
        {
            movement -= Float3.UnitX * Time.DeltaTime * metersPerSecond;
        }

        characterController.Res.Move(movement);
    }
}