using System;
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
    Running,
    Jumping,
    Falling
}

public class PlayerController : MonoBehaviour
{
    // Scene references
    public CharacterController? characterController;
    public GameObject? followTarget;
    public AnimationComponent? animationComponent;

    // Animation clips
    public AssetRef<AnimationClip> idleAnimation;
    public AssetRef<AnimationClip> walkingAnimation;
    public AssetRef<AnimationClip> runningAnimation;
    public AssetRef<AnimationClip> jumpingAnimation;

    // Camera
    public float LookSensitivity = 0.2f;
    public float CameraDistance = 5f;
    public float CameraHeight = 1.5f;
    public float CameraRightOffset = 0.7f;
    public float PitchMin = -40f;
    public float PitchMax = 70f;
    public float CameraSmoothing = 12f;

    // Movement
    public float MoveSpeed = 5.0f;
    public float RunSpeed = 9.0f;
    public float CrouchMoveSpeed = 2.5f;
    public float JumpForce = 8.0f;
    public float Gravity = 20.0f;
    public float StandingHeight = 1.8f;
    public float CrouchHeight = 0.9f;
    public float TurnSpeed = 720f;
    public float IdleDeadzone = 0.1f;
    public float DieIfBelowHeightOf = -30f;

    // Debug
    public bool ShowDebug = true;
    public PlayerAnimationState currentState = PlayerAnimationState.Idle;

    // Camera state
    private float _cameraYaw;
    private float _cameraPitch;
    private Float3 _smoothedCamPos;

    // Movement state
    private Float3 _velocity = Float3.Zero;
    private bool _isCrouching;
    private bool _isRunning;
    private Float3 _startPos;

    public override void OnEnable()
    {
        if (characterController != null)
        {
            _startPos = characterController.Transform.Position;

            // Seed yaw from the character's current Y rotation so camera starts behind it
            var q = characterController.Transform.Rotation;
            _cameraYaw = MathF.Atan2(2f * (q.W * q.Y + q.X * q.Z),
                                      1f - 2f * (q.Y * q.Y + q.Z * q.Z))
                         * (180f / MathF.PI);
        }

        _cameraPitch = 20f;
        _smoothedCamPos = ComputeTargetCamPos();

        Input.LockCursor();

        if (animationComponent != null && idleAnimation.Res != null)
            animationComponent.CurrentClip = idleAnimation.Res;
    }

    public override void Update()
    {
        if (characterController == null || followTarget == null) return;

        // Respawn below kill plane
        if (characterController.Transform.Position.Y < DieIfBelowHeightOf)
        {
            characterController.Transform.Position = _startPos;
            _velocity = Float3.Zero;
            _smoothedCamPos = ComputeTargetCamPos();
            return;
        }

        // Mouse look
        Float2 mouse  = Input.MouseDelta;
        _cameraYaw   += mouse.X * LookSensitivity;
        _cameraPitch += mouse.Y * LookSensitivity;
        _cameraPitch  = MathF.Max(PitchMin, MathF.Min(PitchMax, _cameraPitch));

        // Orbit camera — smooth position, then point at pivot
        Float3 pivot     = followTarget.Transform.Position;
        Float3 targetPos = ComputeTargetCamPos();
        _smoothedCamPos  = Float3.Slerp(_smoothedCamPos, targetPos, Time.DeltaTime * CameraSmoothing);
        this.GameObject.Transform.Position = _smoothedCamPos;
        this.GameObject.Transform.LookAt(pivot, Float3.UnitY);

        if (!Application.IsPlaying) return;

        if (Input.GetKeyDown(KeyCode.Escape))
            Input.UnlockCursor();

        // Input
        float inputX   = 0f, inputZ = 0f;
        if (Input.GetKey(KeyCode.W)) inputZ += 1f;
        if (Input.GetKey(KeyCode.S)) inputZ -= 1f;
        if (Input.GetKey(KeyCode.A)) inputX -= 1f;
        if (Input.GetKey(KeyCode.D)) inputX += 1f;
        bool jumpPressed = Input.GetKeyDown(KeyCode.Space);
        bool crouchHeld  = Input.GetKey(KeyCode.ControlLeft);
        _isRunning       = Input.GetKey(KeyCode.ShiftLeft);

        HandleCrouch(crouchHeld);

        // Camera-relative movement (flat XZ, derived from yaw only)
        Quaternion yawRot = Quaternion.FromEuler(0f, _cameraYaw, 0f);
        Float3 camFwd     = yawRot * new Float3(0f, 0f, 1f);
        Float3 camRight   = yawRot * new Float3(1f, 0f, 0f);

        Float3 rawMove = camFwd * inputZ + camRight * inputX;
        float  rawLen  = Float3.Length(rawMove);
        Float3 moveDir = rawLen > 0.001f ? rawMove * (1f / rawLen) : Float3.Zero;

        float speed  = _isCrouching ? CrouchMoveSpeed
                     : _isRunning   ? RunSpeed
                     : MoveSpeed;
        _velocity.X = moveDir.X * speed;
        _velocity.Z = moveDir.Z * speed;

        // Character body always tracks camera yaw (Gears-of-War style)
        Quaternion targetCharRot  = Quaternion.LookRotation(camFwd, Float3.UnitY);
        Quaternion currentCharRot = characterController.Transform.Rotation;
        characterController.Transform.Rotation =
            MoveTowardsQuat(currentCharRot, targetCharRot, TurnSpeed * Time.DeltaTime);

        HandleGravityAndJump(jumpPressed);
        characterController.Move(_velocity * Time.DeltaTime);
        UpdateAnimations(rawLen, speed);
    }

    private Float3 ComputeTargetCamPos()
    {
        if (followTarget == null) return this.GameObject.Transform.Position;
        Float3 pivot   = followTarget.Transform.Position;
        Quaternion rot = Quaternion.FromEuler(_cameraPitch, _cameraYaw, 0f);
        Float3 arm     = rot * new Float3(CameraRightOffset, 0f, -CameraDistance);
        return pivot + arm;
    }

    private void HandleCrouch(bool crouchHeld)
    {
        if (crouchHeld && !_isCrouching)
        {
            if (characterController.TrySetHeight(CrouchHeight))
                _isCrouching = true;
        }
        else if (!crouchHeld && _isCrouching)
        {
            if (characterController.TrySetHeight(StandingHeight))
                _isCrouching = false;
        }
    }

    private void HandleGravityAndJump(bool jumpPressed)
    {
        if (!characterController.IsGrounded)
        {
            _velocity.Y -= Gravity * Time.DeltaTime;
        }
        else
        {
            if (_velocity.Y < 0f) _velocity.Y = 0f;
            if (jumpPressed && !_isCrouching) _velocity.Y = JumpForce;
        }
    }

    private void UpdateAnimations(float horizontalSpeed, float maxSpeed)
    {
        if (animationComponent == null) return;

        bool airborne = !characterController.IsGrounded;

        PlayerAnimationState desired;
        if (airborne && _velocity.Y > 0f)
            desired = PlayerAnimationState.Jumping;
        else if (airborne)
            desired = PlayerAnimationState.Falling;
        else if (horizontalSpeed > IdleDeadzone && _isRunning && runningAnimation.Res != null)
            desired = PlayerAnimationState.Running;
        else if (horizontalSpeed > IdleDeadzone)
            desired = PlayerAnimationState.Walking;
        else
            desired = PlayerAnimationState.Idle;

        // Fall back to walk/idle if no jump clip assigned
        if ((desired == PlayerAnimationState.Jumping || desired == PlayerAnimationState.Falling)
            && jumpingAnimation.Res == null)
            desired = horizontalSpeed > IdleDeadzone ? PlayerAnimationState.Walking : PlayerAnimationState.Idle;

        if (desired != currentState)
        {
            AnimationClip? clip = ClipFor(desired);
            if (clip != null)
            {
                animationComponent.CurrentClip = clip;
                currentState = desired;
            }
        }

        if (!animationComponent.IsPlaying)
        {
            AnimationClip? loop = ClipFor(currentState);
            if (loop != null) animationComponent.Play(loop);
        }

        bool isMoving = currentState == PlayerAnimationState.Walking
                     || currentState == PlayerAnimationState.Running;
        animationComponent.Speed = isMoving && maxSpeed > 0f
            ? MathF.Max(horizontalSpeed / maxSpeed, 0.1f)
            : 1f;
    }

    private AnimationClip? ClipFor(PlayerAnimationState state) => state switch
    {
        PlayerAnimationState.Idle    => idleAnimation.Res,
        PlayerAnimationState.Walking => walkingAnimation.Res,
        PlayerAnimationState.Running => runningAnimation.Res ?? walkingAnimation.Res,
        PlayerAnimationState.Jumping => jumpingAnimation.Res,
        PlayerAnimationState.Falling => jumpingAnimation.Res,
        _                            => idleAnimation.Res,
    };

    private static Quaternion MoveTowardsQuat(Quaternion from, Quaternion to, float maxDegrees)
    {
        float angle = Quaternion.Angle(from, to);
        if (angle == 0f) return to;
        return Quaternion.Slerp(from, to, Maths.Min(1f, maxDegrees / angle));
    }

    // Debug colors
    private readonly Color _velColor   = new Color(255, 255,   0, 255);  // yellow — velocity
    private readonly Color _aimColor   = new Color(  0, 255,   0, 255);  // green  — camera aim ray
    private readonly Color _orbitColor = new Color(  0, 255, 255, 255);  // cyan   — orbit arm
    private readonly Color _fwdColor   = new Color(255, 255, 255, 255);  // white  — character facing

    public override void DrawGizmos()
    {
        if (!ShowDebug || characterController == null) return;

        Float3 charPos = characterController.Transform.Position;
        Float3 camPos  = this.GameObject.Transform.Position;

        // Horizontal velocity arrow (yellow)
        Float3 hVel = new Float3(_velocity.X, 0f, _velocity.Z);
        if (Float3.Length(hVel) > 0.1f)
            Debug.DrawArrow(charPos + Float3.UnitY * 0.5f, hVel * 0.4f, _velColor);

        // Camera aim ray forward (green) — where camera is pointing into the scene
        Debug.DrawArrow(camPos, this.GameObject.Transform.Forward * 5f, _aimColor);

        // Orbit arm (cyan) — line from pivot to camera
        if (followTarget != null)
            Debug.DrawLine(followTarget.Transform.Position, camPos, _orbitColor);

        // Character facing direction (white)
        Debug.DrawArrow(charPos + Float3.UnitY * 0.5f,
                        characterController.Transform.Forward * 1.5f, _fwdColor);
    }
}
