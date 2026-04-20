using Prowl.Runtime;

using Prowl.Echo;
using Prowl.Editor;
using Prowl.Runtime.Resources;
using Prowl.Vector;

[ExecuteAlways]
public class PlayerController : MonoBehaviour
{
    public CharacterController? characterController;
    public GameObject? lookAtTarget;
    public GameObject? followTarget;
    
    public Float3 offset = new Float3(10, 10, 10);
    
    public float MoveSpeed = 5.0f;
    public float CrouchMoveSpeed = 2.5f;
    public float JumpForce = 8.0f;
    public float Gravity = 20.0f;
    public float StandingHeight = 1.8f;
    public float CrouchHeight = 0.9f;
    
    private Float3 velocity = Float3.Zero;
    private Float3 moveInput = Float3.Zero;
    private bool jumpInput = false;
    private bool crouchInput = false;
    private bool isCrouching = false;

    public override void Update()
    {
        if (characterController == null ||
            lookAtTarget == null ||
            followTarget == null) return;
        
        this.GameObject.Transform.Position = followTarget.Transform.Position + offset;
        this.GameObject.Transform.LookAt(lookAtTarget.Transform.Position, Float3.UnitY);
        
        if (!Application.IsPlaying) return;
        
        moveInput = Float3.Zero;
        if (Input.GetKey(KeyCode.W)) moveInput += new Float3(0, 0, 1);
        if (Input.GetKey(KeyCode.S)) moveInput -= new Float3(0, 0, 1);
        if (Input.GetKey(KeyCode.A)) moveInput -= new Float3(1, 0, 0);
        if (Input.GetKey(KeyCode.D)) moveInput += new Float3(1, 0, 0);
        moveInput = Float3.Normalize(moveInput);
        
        jumpInput = Input.GetKeyDown(KeyCode.Space);
        crouchInput = Input.GetKey(KeyCode.ControlLeft);
        
        // Handle crouching
        HandleCrouch();
        
        // Update horizontal velocity based on input
        float currentSpeed = isCrouching ? CrouchMoveSpeed : MoveSpeed;
        Float3 horizontalVelocity = moveInput * currentSpeed;
        velocity.X = horizontalVelocity.X;
        velocity.Z = horizontalVelocity.Z;
        
        HandleGravityAndJump();
        
        // Calculate total movement for this frame
        Float3 movement = velocity * Time.DeltaTime;
        
        // Move the character using the CharacterController (this also updates IsGrounded)
        characterController.Move(movement);
    }

    private void HandleCrouch()
    {
        if (crouchInput && !isCrouching)
        {
            // Try to crouch
            if (characterController.TrySetHeight(CrouchHeight))
            {
                isCrouching = true;
            }
        }
        else if (!crouchInput && isCrouching)
        {
            // Try to stand up (only if there's clearance above)
            if (characterController.TrySetHeight(StandingHeight))
            {
                isCrouching = false;
            }
            // If TrySetHeight fails, player remains crouched (not enough clearance)
        }
    }

    private void HandleGravityAndJump()
    {
        if (!characterController.IsGrounded)
        {
            velocity.Y -= Gravity * Time.DeltaTime;
        }
        else
        {
            if (velocity.Y < 0)
                velocity.Y = 0;

            // Handle jump when grounded (can't jump while crouching)
            if (jumpInput && !isCrouching)
            {
                velocity.Y = JumpForce;
            }
        }
    }

    public override void DrawGizmos()
    {
        // Draw velocity
        if (Float3.Length(velocity) > 0.1)
        {
            Float3 position = GameObject.Transform.Position;
            Debug.DrawArrow(position, velocity * 0.5f, new Color(255, 255, 0, 255));
        }
    }
}