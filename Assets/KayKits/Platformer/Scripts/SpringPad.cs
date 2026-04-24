using Prowl.Runtime;

namespace KayKits.Platformer;

public class SpringPad : MonoBehaviour
{
    public GameObject? SpringModel;
    public Rigidbody3D? SpringRigidbody;
    
    public override void OnEnable()
    {
        SpringRigidbody.BeginCollide += Collided;
    }

    public override void OnDisable()
    {
        SpringRigidbody.BeginCollide -= Collided;
    }

    private void Collided(Rigidbody3D otherBody, Rigidbody3D.ContactInfo contactInfo)
    {
        
    }

    public override void Update()
    {
    }
}
