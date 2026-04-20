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
        if (Input.GetKey(KeyCode.Number1))
        {
            Focus();
        }

        this.Transform.Position = followTarget.Position + offset;
        this.Transform.LookAt(lookAtTarget.Position);

        Float3 movement;
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

        playerController.Move(movement);
    }
}