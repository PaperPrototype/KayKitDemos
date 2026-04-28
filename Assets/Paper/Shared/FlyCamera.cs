using System;

using Prowl.Runtime;
using Prowl.Vector;

public class FlyCamera : MonoBehaviour
{
    public float MoveSpeed = 10f;
    public float SprintMultiplier = 3f;
    public float LookSensitivity = 0.2f;

    private float _yaw;
    private float _pitch;
    private float _speed;

    public override void OnEnable()
    {
        Input.LockCursor();
    }

    public override void Update()
    {
        Float2 mouseDelta = Input.MouseDelta;
        _yaw += mouseDelta.X * LookSensitivity;
        _pitch += mouseDelta.Y * LookSensitivity;
        _pitch = MathF.Max(-89f, MathF.Min(89f, _pitch));
        Transform.Rotation = Quaternion.FromEuler(_pitch, _yaw, 0f);

        _speed = MoveSpeed * (Input.GetKey(KeyCode.ShiftLeft) ? SprintMultiplier : 1f);

        Float3 move = Float3.Zero;
        if (Input.GetKey(KeyCode.W)) move += Transform.Forward;
        if (Input.GetKey(KeyCode.S)) move -= Transform.Forward;
        if (Input.GetKey(KeyCode.A)) move -= Transform.Right;
        if (Input.GetKey(KeyCode.D)) move += Transform.Right;
        if (Input.GetKey(KeyCode.E)) move += Float3.UnitY;
        if (Input.GetKey(KeyCode.Q)) move -= Float3.UnitY;

        Transform.Position += move * _speed * Time.DeltaTime;
    }
}
