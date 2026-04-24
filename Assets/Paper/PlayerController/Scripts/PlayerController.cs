using Prowl.Runtime;

using Prowl.Echo;
using Prowl.Editor;
using Prowl.Runtime.Resources;
using Prowl.Vector;

namespace Paper;

public enum PlayerAnimationState
{
    Idle,
    Walking,
    // Running,
    // Jumping,
    // Crouching
}

//[ExecuteAlways]
public class PlayerController : MonoBehaviour
{
    public CharacterController? characterController;
    public GameObject? lookAtTarget;
    public GameObject? followTarget;
    
    public AnimationComponent? animationComponent;
    public AssetRef<AnimationClip> idleAnimation;
    public AssetRef<AnimationClip> walkingAnimation;
    // public AssetRef<AnimationClip> runningAnimation;
    // public AssetRef<AnimationClip> jumpingAnimation;
    // public AssetRef<AnimationClip> crouchAnimation;
    public PlayerAnimationState currentState = PlayerAnimationState.Idle;
    
    public Float3 offset = new Float3(10, 10, 10);
    
    public float MoveSpeed = 5.0f;
    public float CrouchMoveSpeed = 2.5f;
    public float JumpForce = 8.0f;
    public float Gravity = 20.0f;
    public float StandingHeight = 1.8f;
    public float CrouchHeight = 0.9f;
    public float IdleDeadzone = 0.2f;
    public float MetersPerSecondSmooth = 1f;
    public float DegreesPerSecondSmooth = 1f;
    public float DieIfBelowHeightOf = -30;
    
    private Float3 smoothedLookAtTarget = Float3.Zero;
    private Float3 velocity = Float3.Zero;
    private Float3 moveInput = Float3.Zero;
    private bool jumpInput = false;
    private bool crouchInput = false;
    private bool isCrouching = false;
    
    private Float3 startPos = Float3.Zero;

    public override void OnEnable()
    {
        startPos = characterController.Transform.Position;
        animationComponent.CurrentClip = GetAnimationState(PlayerAnimationState.Idle);
    }

    public override void Update()
    {
        if (characterController.Transform.Position.Y < DieIfBelowHeightOf)
        {
            characterController.Transform.Position = startPos;
            smoothedLookAtTarget = lookAtTarget.Transform.Position;
            this.GameObject.Transform.Position = followTarget.Transform.Position + offset;
            this.GameObject.Transform.LookAt(lookAtTarget.Transform.Position, Float3.UnitY);
        }
        
        Quaternion MoveTowards(Quaternion from, Quaternion to, float maxDegreesDelta)
        {
            float angle = Quaternion.Angle(from, to);

            if (angle == 0f)
                return to;

            float t = Maths.Min(1f, maxDegreesDelta / angle);

            return Quaternion.Slerp(from, to, t);
        }
        
        if (characterController == null ||
            lookAtTarget == null ||
            followTarget == null) return;

        smoothedLookAtTarget = Float3.Slerp(smoothedLookAtTarget, lookAtTarget.Transform.Position,
            Time.DeltaTime * MetersPerSecondSmooth);
        
        this.GameObject.Transform.Position = Float3.Slerp(this.GameObject.Transform.Position, followTarget.Transform.Position + offset, Time.DeltaTime * MetersPerSecondSmooth);
        this.GameObject.Transform.LookAt(smoothedLookAtTarget, Float3.UnitY);
        
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
        
        // rotate character to look in move velocity
        // characterController.Transform.Forward = horizontalVelocity;

        var targetRot = Quaternion.LookRotation(horizontalVelocity, Float3.UnitY);
        var currentRot = characterController.Transform.Rotation;
        characterController.Transform.Rotation = MoveTowards(currentRot, targetRot, Time.DeltaTime * DegreesPerSecondSmooth);

        HandleGravityAndJump();
        
        // Calculate total movement for this frame
        Float3 movement = velocity * Time.DeltaTime;
        
        // Move the character using the CharacterController (this also updates IsGrounded)
        characterController.Move(movement);
        
        if (animationComponent == null ||
            walkingAnimation == null ||
            // runningAnimation == null ||
            // jumpingAnimation == null ||
            idleAnimation == null) return;

        var relativeVelocityLength = Float3.Length(horizontalVelocity) / currentSpeed;
        
        // if walking but velocity has decreased then switch to idle
        if (relativeVelocityLength < IdleDeadzone && currentState == PlayerAnimationState.Walking)
        {
            animationComponent.CurrentClip = GetAnimationState(PlayerAnimationState.Idle);
        }
        
        // if we are idle but the current velocity has increased then switch to walking
        if (relativeVelocityLength > IdleDeadzone && currentState == PlayerAnimationState.Idle)
        {
            animationComponent.CurrentClip = GetAnimationState(PlayerAnimationState.Walking);
        }
        
        // loop the animation
        if (!animationComponent.IsPlaying)
        {
            animationComponent.Play(GetAnimationState(currentState));
        }
        
        if (currentState == PlayerAnimationState.Walking) {
            animationComponent.Speed = relativeVelocityLength;
        }
        else
        {
            animationComponent.Speed = 1;
        }
    }

    private AnimationClip GetAnimationState(PlayerAnimationState newState)
    {
        switch (newState)
        {
            case PlayerAnimationState.Idle:
                currentState = PlayerAnimationState.Idle;
                return idleAnimation.Res;
            case PlayerAnimationState.Walking:
                currentState = PlayerAnimationState.Walking;
                return walkingAnimation.Res;
            // case PlayerAnimationState.Running:
            //     animationComponent.CurrentClip = runningAnimation.Res;
            //     break;
            // case PlayerAnimationState.Jumping:
            //     animationComponent.CurrentClip = jumpingAnimation.Res;
            //     break;
            // case PlayerAnimationState.Crouching:
            //     animationComponent.CurrentClip = crouchAnimation.Res;
            //     break;
                
        }
        
        return idleAnimation.Res;
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