# Tutorial: Implement Elastic Load Balancer in AWS

This tutorial will teach you how to implement an Application Load Balancer using AWS ELB to route traffic among instances in different avaliability zones.

## Architecture

![Architecture](/assets/architecture.jpg)

## Workflow

For this tutorial we'll use almost the same configuration that the one explained in the [Application Load Balancer's tutorial](https://github.com/rtalexk/elb_application). But in this one we'll use an auto scaling group to group together EC2 instances and ensure a certain ammount of instances keep running at the same time.

We'll use also an Application Load Balancer inside a Security Group that gets traffic from outside and routes to the instances inside the Auto Scalig Group. Each instance also will have its Auto Scaling Group that accepts traffic from the Load Balancer and sends to the outside.

We'll configure the Auto Scaling Group to keep running always two instances and it will do its best to provision them in different availability zones.

Aunto Scaling Group uses a Launch Template which defines the configuration of the newly provisioned instances.

Once an unhealthy instance is detected by the ELB's Target Group it will notify to the ASG which will provision a new one to replace it. Also the ASG takes care of registering the new instance with the ELB once it is healty so the ELB can route traffic to it.

## Prerequisites

This tutorial asumes you have an AWS account and you've configured AWS credentials for CLI, if you haven't [please do so](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html#post-install-configure).

I have configured the CLI to use the `us-east-1` region, so all the resources will be created in this region.

To follow the procedures in this tutorial you'll need a command line terminal to run commands. Commands are shown as below:

```
(bash) $ command
----------------
output
```

`(bash) $ ` is a constant indicating that is a command running in bash. Everything below `--------------` is the output of the command, or if the response is a JSON, it will have its own section denoted by **Output:** header.

> **IMPORTANT!** Make sure to replace ID parameters in all the AWS commands.

Also I'm using `jq`, a command line tool used to extract information from `JSON` data, example: the following command returns a JSON with the information of the `VPC`s:

```shell
(bash) $ aws ec2 describe-vpcs
```

Output:

```json
{
  "Vpcs": [
    {
      "VpcId": "vpc-d64fd4ac",
      "InstanceTenancy": "default",
      "CidrBlockAssociationSet": [
        {
          "AssociationId": "vpc-cidr-assoc-38a5d154",
          "CidrBlock": "172.31.0.0/16",
          "CidrBlockState": {
            "State": "associated"
          }
        }
      ],
      "State": "available",
      "DhcpOptionsId": "dopt-0c363277",
      "OwnerId": "436887685341",
      "CidrBlock": "172.31.0.0/16",
      "IsDefault": true
    }
  ]
}
```

But, as I'm only interested in the `VpcId` field of my default `VPC`, I can use `jq` to extract only that field:

```shell
(bash) $ aws ec2 describe-vpcs | jq '.Vpcs | .[0] | .VpcId'
--------------
"vpc-d64fd4ac"
```

Explanation:

`aws ec2 describe-vpcs` return a `JSON` object. I use the pipe operator `|` to send the JSON to the `jq` command. `jq` takes an string as input describing how you want to filter the data delimited either by `'` or `"`. Here I'll be using `'`. The input string of `jq` has its own syntax, which you can consult in the [official documentation](https://stedolan.github.io/jq/manual). First I extract the `Vpcs` field from the `JSON` data, `Vpcs` is an array. As you can see `jq` also make use of the pipe operator `|`, once I extracted `Vpcs` field it results in an array, I use `|` to take that array as input and extract the first element `.[0]`, that results in an object with the information of the `VPC`, and again I use the pipe operator to extract the `VpcId` field.

I'm using `jq` only to make te output shorter for the sake of the length of the tutorial text.

Feel free to not use `jq` and only copy the `aws` commands and look for the information by your own.

To install in Mac simple run the command `brew install jq`.

## Security Groups

First we'll create the security groups for the EC2 instances and for the Load Balancer.

To create a security group we use the following API:

```
aws ec2 create-security-group --description <value> --group-name <value> [--vpc-id <value>]
```

For that reasson we require to have the **VPC Id** in which the SGs will be breated on.

To get the **VPC Id** we use the following command:

```shell
(bash) $ aws ec2 describe-vpcs | jq '.Vpcs | .[0] | .VpcId'
--------------
"vpc-d64fd4ac"
```

Now I can create the security groups:

```bash
(bash) $ aws ec2 create-security-group --group-name asg-elb-sg --vpc-id vpc-d64fd4ac --description "SG that would be assigned to the ELB. Inbound from public, outbound to EC2 SG."
```

Output:

```json
{
  "GroupId": "sg-0711cbbfafffcfc90"
}
```

```bash
(bash) $ aws ec2 create-security-group --group-name asg-elb-ec2-sg --vpc-id vpc-d64fd4ac --description "SG that would be assigned to the EC2 instances. Inbound from EC2 SG, outbound to public."
```

Output:

```json
{
  "GroupId": "sg-0e2ef5fc627df4419"
}
```

By default, all security groups has an outbound rule assigned that enables any protocol to any IP, and we can verify that:

```bash
(bash) $ aws ec2 describe-security-groups --group-id sg-0711cbbfafffcfc90 | jq '.SecurityGroups | map(select(.GroupId == "sg-0711cbbfafffcfc90")) | .[0] | .IpPermissionsEgress'
```

Output:

```json
[
  {
    "IpProtocol": "-1",
    "PrefixListIds": [],
    "IpRanges": [
      {
        "CidrIp": "0.0.0.0/0"
      }
    ],
    "UserIdGroupPairs": [],
    "Ipv6Ranges": []
  }
]
```

`ip-Protocol: "-1"` refers to any protocol. `ipRanges.[0].CidrIp: "0.0.0.0/0` refers to anywhere. In summary any protocol to anywhere.

For security reasons we're going to remove that rule and assign our own.

### Revoke default outbound rules

```bash
(bash) $ aws ec2 revoke-security-group-egress --group-id sg-0711cbbfafffcfc90 --ip-permissions '[{ "IpProtocol": "-1", "IpRanges": [{ "CidrIp": "0.0.0.0/0" }] }]'
```

Note that the rule you're revoking must match exaclty.

Now, you can verify that tue rule was removed successfuly by running again the describe command:

```bash
(bash) $ aws ec2 describe-security-groups --group-id sg-0711cbbfafffcfc90 | jq '.SecurityGroups | .[0] | .IpPermissionsEgress'
--------------
[]
```

Run again the same command to revoke outboud permissions but now with the other security group:

```bash
(bash) $ aws ec2 revoke-security-group-egress --group-id sg-0e2ef5fc627df4419 --ip-permissions '[{ "IpProtocol": "-1", "IpRanges": [{ "CidrIp": "0.0.0.0/0" }] }]'
```

And verify it was executed successfuly:

```bash
(bash) $ aws ec2 describe-security-groups --group-id sg-0e2ef5fc627df4419 | jq '.SecurityGroups | .[0] | .IpPermissionsEgress'
--------------
[]
```

### Add inbound and outboud rules

Remember, ELB must accept HTTP requests from anywhere and must be able to reach EC2, and EC2 must be able to accept HTTP requests from ELB and send HTTP responses to anywhere.

```bash
(bash) $ aws ec2 authorize-security-group-ingress --group-id sg-0711cbbfafffcfc90 --protocol tcp --port 80 --cidr 0.0.0.0/0
```

To verify:

```bash
(bash) $ aws ec2 describe-security-groups --group-id sg-0711cbbfafffcfc90 | jq '.SecurityGroups | .[0] | .IpPermissions'
```

Output:

```json
[
  {
    "PrefixListIds": [],
    "FromPort": 80,
    "IpRanges": [
      {
        "CidrIp": "0.0.0.0/0"
      }
    ],
    "ToPort": 80,
    "IpProtocol": "tcp",
    "UserIdGroupPairs": [],
    "Ipv6Ranges": []
  }
]
```

Now, let's add outbound rules.

```bash
(bash) $ aws ec2 authorize-security-group-egress --group-id sg-0711cbbfafffcfc90 --protocol tcp --port 80 --source-group sg-0c1018438bf942a
```

To verify:

```bash
(bash) $ aws ec2 describe-security-groups --group-id sg-0711cbbfafffcfc90 | jq '.SecurityGroups | .[0] | .IpPermissionsEgress'
```

Output:

```json
[
  {
    "PrefixListIds": [],
    "FromPort": 80,
    "IpRanges": [],
    "ToPort": 80,
    "IpProtocol": "tcp",
    "UserIdGroupPairs": [
      {
        "UserId": "436887685341",
        "GroupId": "sg-0e2ef5fc627df4419"
      }
    ],
    "Ipv6Ranges": []
  }
]
```

Now let's do the same with the EC2 SG.

```bash
(bash) $ aws ec2 authorize-security-group-ingress --group-id sg-0e2ef5fc627df4419 --protocol tcp --port 80 --source-group sg-0711cbbfafffcfc90
```

```bash
(bash) $ aws ec2 authorize-security-group-egress --group-id sg-0e2ef5fc627df4419 --protocol tcp --port 80 --cidr 0.0.0.0/0
```

```bash
(bash) $ aws ec2 authorize-security-group-egress --group-id sg-0e2ef5fc627df4419 --protocol tcp --port 443 --cidr 0.0.0.0/0
```

> Note that we're oppening both HTTP (TCP at port 80) and HTTPS (TCP at port 443). In this example we're not using HTTPS to communicate client with our application, but inside the EC2 instances we're downloading code from Github which uses HTTPS to do so.

Our security groups are now configured as described in the architecture. Let's continue with the Auto Scaling configuration.

For that we first need to create a Launch Template, which includes the parameters required to launch an EC2 instance, such as the ID of the Amazon Machine Image (AMI) and an instance type.

## Lauch Template

```bash
(bash) $ aws ec2 create-launch-template --launch-template-name asg-template --version-description "Version 1" --launch-template-data '{ "NetworkInterfaces": [{ "DeviceIndex": 0, "AssociatePublicIpAddress": true, "Groups": ["sg-0e2ef5fc627df4419"], "DeleteOnTermination": true }], "ImageId": "ami-0b69ea66ff7391e80", "InstanceType": "t2.micro", "UserData": "IyEvYmluL2Jhc2gKCnl1bSB1cGRhdGUgLXkKCiMgRG93bmxvYWQgY29kZQp3Z2V0IGh0dHBzOi8vZ2l0aHViLmNvbS9ydGFsZXhrL2VsYl9jbGFzc2ljL2FyY2hpdmUvbWFzdGVyLnppcAp1bnppcCBtYXN0ZXIuemlwCnJtIC1mIG1hc3Rlci56aXAKCiMgaW5zdGFsbCBOb2RlLmpzCmN1cmwgLW8tIGh0dHBzOi8vcmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbS9udm0tc2gvbnZtL3YwLjM0LjAvaW5zdGFsbC5zaCB8IGJhc2gKCmV4cG9ydCBOVk1fRElSPSIkSE9NRS8ubnZtIgpbIC1zICIkTlZNX0RJUi9udm0uc2giIF0gJiYgXC4gIiROVk1fRElSL252bS5zaCIKCi4gfi8ubnZtL252bS5zaApudm0gaW5zdGFsbCAxMAoKd2hpY2ggbm9kZQp3aGljaCBub2RlanMKCiMgSW5zdGFsbCBjb2RlCmNkIGVsYl9hcHBsaWNhdGlvbi1tYXN0ZXIKbnBtIGluc3RhbGwKCiMgSW5zdGFsbCBOZ2lueAphbWF6b24tbGludXgtZXh0cmFzIGluc3RhbGwgbmdpbngxLjEyIC15CgojIENvbmZpZ3VyZSBOZ2lueCBQcm94eQptdiAvZXRjL25naW54L25naW54LmNvbmYgL2V0Yy9uZ2lueC9uZ2lueC5jb25mLmJhawpjcCAuL2J1aWxkL25naW54LmNvbmYgL2V0Yy9uZ2lueC9uZ2lueC5jb25mCnNlcnZpY2UgbmdpbnggcmVzdGFydAoKIyBTdGFydCBOZ2lueCBvbiBzZXJ2ZXIgcmVzdGFydApjaGtjb25maWcgbmdpbnggb24KCiMgUnVuIHByb2plY3QKbnBtIHN0YXJ0Cg==" }'
```

Output:

```json
{
  "LaunchTemplate": {
    "LatestVersionNumber": 1,
    "LaunchTemplateId": "lt-0998cc95c857b9c7f",
    "LaunchTemplateName": "asg-template",
    "DefaultVersionNumber": 1,
    "CreatedBy": "arn:aws:iam::436887685341:user/rtadmin",
    "CreateTime": "2019-09-09T18:05:14.000Z"
  }
}
```

This Launch Template also includes User Data which will be executed once the instance is in running state. This user data is available at [`build/user_data.sh`](/build/user_data.sh) and installs Node.js and configured the project to be running in port 3000 and uses Nginx as reverse proxy to proxy port 80 to 3000.

## Elastic Load Balancer

Now it's time to create the Load Balancer, in this case we'll use the same configuration used in [Application Load Balancer's tutorial](https://github.com/rtalexk/elb_application).

```bash
(bash) $ aws elbv2 create-load-balancer --name asg-balancer --subnets "subnet-4bc9862c" "subnet-0d024951" --security-groups sg-0711cbbfafffcfc90 --type application
```

In this command we specify the subnet IDs on which the Load Balancer can route to. Also notice that I'm specifying to use an `application` load balancer as `type`. It's not required to specify the type for an ALB due to this is the default value.

The outpot of the previous command is the information of the newly created ELB in `provisioning` state.

```json
{
  "LoadBalancers": [
    {
      "IpAddressType": "ipv4",
      "VpcId": "vpc-d64fd4ac",
      "LoadBalancerArn": "arn:aws:elasticloadbalancing:us-east-1:436887685341:loadbalancer/app/asg-balancer/8459ebfe9e1b337c",
      "State": {
        "Code": "provisioning"
      },
      "DNSName": "asg-balancer-458942390.us-east-1.elb.amazonaws.com",
      "SecurityGroups": [
        "sg-0711cbbfafffcfc90"
      ],
      "LoadBalancerName": "asg-balancer",
      "CreatedTime": "2019-09-09T18:13:29.660Z",
      "Scheme": "internet-facing",
      "Type": "application",
      "CanonicalHostedZoneId": "Z35SXDOTRQ7X7K",
      "AvailabilityZones": [
        {
          "SubnetId": "subnet-0d024951",
          "ZoneName": "us-east-1a"
        },
        {
          "SubnetId": "subnet-4bc9862c",
          "ZoneName": "us-east-1b"
        }
      ]
    }
  ]
}
```

### Target Group

Your load balancer routes requests to the targets in this target group using the protocol and port that you specify, and performs health checks on the targets using these health check settings.

```bash
(bash) $ aws elbv2 create-target-group --name asg-instances --target-type instance --vpc-id vpc-d64fd4ac \
    --protocol HTTP --port 80 --health-check-path /health
```

Output:

```json
{
  "TargetGroups": [
    {
      "HealthCheckPath": "/health",
      "HealthCheckIntervalSeconds": 30,
      "VpcId": "vpc-d64fd4ac",
      "Protocol": "HTTP",
      "HealthCheckTimeoutSeconds": 5,
      "TargetType": "instance",
      "HealthCheckProtocol": "HTTP",
      "Matcher": {
        "HttpCode": "200"
      },
      "UnhealthyThresholdCount": 2,
      "HealthyThresholdCount": 5,
      "TargetGroupArn": "arn:aws:elasticloadbalancing:us-east-1:436887685341:targetgroup/asg-instances/2c7ee38c3dd69267",
      "HealthCheckEnabled": true,
      "HealthCheckPort": "traffic-port",
      "Port": 80,
      "TargetGroupName": "asg-instances"
    }
  ]
}
```

### Create a Listener for the ELB

A listener is a process that checks for connection requests, using the protocol and port that you configured. It basically forwards requests made to the ELB to the Target Group.

```bash
(bash) $ aws elbv2 create-listener --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:436887685341:loadbalancer/app/asg-balancer/8459ebfe9e1b337c \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:us-east-1:436887685341:targetgroup/asg-instances/2c7ee38c3dd69267
```

Output:

```json
{
  "Listeners": [
    {
      "Protocol": "HTTP",
      "DefaultActions": [
        {
          "TargetGroupArn": "arn:aws:elasticloadbalancing:us-east-1:436887685341:targetgroup/asg-instances/2c7ee38c3dd69267",
          "Type": "forward"
        }
      ],
      "LoadBalancerArn": "arn:aws:elasticloadbalancing:us-east-1:436887685341:loadbalancer/app/asg-balancer/8459ebfe9e1b337c",
      "Port": 80,
      "ListenerArn": "arn:aws:elasticloadbalancing:us-east-1:436887685341:listener/app/asg-balancer/8459ebfe9e1b337c/0d2d44eb55236815"
    }
  ]
}
```

## Auto Scaling Group

With all the resources created and configured now we can create the Auto Scaling Group to link the Launch Template with the Load Balancer. So, anytime an instance is unhealthy, the ASG will launch a new instance using the tamplate as reference and will register that new instance with the Load Balancer.

```bash
(bash) $ aws autoscaling create-auto-scaling-group --auto-scaling-group-name asg-autoscaling \
    --launch-template "LaunchTemplateName=asg-template,Version=1" \
    --target-group-arns arn:aws:elasticloadbalancing:us-east-1:436887685341:targetgroup/asg-instances/2c7ee38c3dd69267 \
    --max-size 2 --min-size 2 --desired-capacity 2 --vpc-zone-identifier "subnet-4bc9862c,subnet-0d024951"
```

With this Auto Scaling Group we're defining a `min-size`, `max-size` and `desired-capacity` of 2, which will ensure that always two instances must be running. And we're defining the Subnets IDs where these instances must be launched on (`--vpc-zone-identifier`).

## Testing

You've finish! Now it's time for testing. Get the URL from the response when you created the Load Balancer, or you can query using the CLI:

```bash
(bash) $ aws elbv2 describe-load-balancers --names az-balancer | jq '.LoadBalancers | .[0] | .DNSName'
----------------
"asg-balancer-458942390.us-east-1.elb.amazonaws.com"
```

Now copy and paste this URL (without the quotation marks `"`) in your favorite browser. Then start refreshing multiple times and you'll see that the application is served from the two different instances.

Also verify that the auto scaling group ensures that the defined ammount of instances keep running by terminating one.

First verify the health status of the registered instances inside the ASG:

```bash
(bash) $ aws elbv2 describe-target-health --target-group-arn arn:aws:elasticloadbalancing:us-east-1:436887685341:targetgroup/asg-instances/2c7ee38c3dd69267
```

Output:

```json
{
  "TargetHealthDescriptions": [
    {
      "HealthCheckPort": "80",
      "Target": {
        "Id": "i-0c9d0dc90368d2fe1",
        "Port": 80
      },
      "TargetHealth": {
        "State": "healthy"
      }
    },
    {
      "HealthCheckPort": "80",
      "Target": {
        "Id": "i-004f291c4441da411",
        "Port": 80
      },
      "TargetHealth": {
        "State": "healthy"
      }
    }
  ]
}
```

As you can see, there're two instances with the state of `healthy`, look at the `Target.Id`s, once we stop an instance another one should be provisioned automatically replacing the unhealthy one, it will cause a new `Id` will be shown up.

Let's terminate an instance:

```bash
(bash) $ aws ec2 terminate-instances --instance-id i-0c9d0dc90368d2fe1
```

Now if we check again the instance status:

```bash
(bash) $ aws elbv2 describe-target-health --target-group-arn arn:aws:elasticloadbalancing:us-east-1:436887685341:targetgroup/asg-instances/2c7ee38c3dd69267
```

Output:

```json
{
  "TargetHealthDescriptions": [
    {
      "HealthCheckPort": "80",
      "Target": {
        "Id": "i-004f291c4441da411",
        "Port": 80
      },
      "TargetHealth": {
        "State": "healthy"
      }
    }
  ]
}
```

There's only one instance in the target group. Once the Target Group detects that there's an instance with an unhealty status will notify to the Auto Scaling which will provision another instance using the Launch Template to configure it. It should take less than 5 minutes as configured in the target group (which defaults to 30 seconds for instance target types).

```bash
(bash) $ aws elbv2 describe-target-health --target-group-arn arn:aws:elasticloadbalancing:us-east-1:436887685341:targetgroup/asg-instances/2c7ee38c3dd69267
```

Output:

```json
{
  "TargetHealthDescriptions": [
    {
      "HealthCheckPort": "80",
      "Target": {
        "Id": "i-00a7bcf0e4c65ff64",
        "Port": 80
      },
      "TargetHealth": {
        "State": "initial",
        "Reason": "Elb.RegistrationInProgress",
        "Description": "Target registration is in progress"
      }
    },
    {
      "HealthCheckPort": "80",
      "Target": {
        "Id": "i-004f291c4441da411",
        "Port": 80
      },
      "TargetHealth": {
        "State": "healthy"
      }
    }
  ]
}
```

As you can see the ASG is now starting a new instance and in a matter of seconds (or minutes) it will become healthy.

## Remove provisioned resources

For this tutorial we provisioned the following resources:

* Elastic Load Balancer
   * Target Group
   * Listener
* EC2 Instances
* Auto Scaling Group
   * Launch Template
* Security Groups

### Delete Elastic Load Balancer

```bash
(bash) $ aws elbv2 delete-load-balancer --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:436887685341:loadbalancer/app/asg-balancer/8459ebfe9e1b337c
```

### Delete Target Group

```bash
(bash) $ aws elbv2 delete-target-group --target-group-arn arn:aws:elasticloadbalancing:us-east-1:436887685341:targetgroup/asg-instances/2c7ee38c3dd69267
```

### Terminate Instances

Query for instances (in my case I only have two instances running, both used for this tutorial):

```bash
(bash) $ aws ec2 describe-instances | jq '.Reservations | .[] | .Instances | .[] | .InstanceId'
----------------
"i-00a7bcf0e4c65ff64"
"i-004f291c4441da411"
```

```bash
(bash) $ aws ec2 terminate-instances --instance-ids "i-00a7bcf0e4c65ff64" "i-004f291c4441da411"
```

Output:

```json
{
  "TerminatingInstances": [
    {
      "InstanceId": "i-00a7bcf0e4c65ff64",
      "CurrentState": {
        "Code": 32,
        "Name": "shutting-down"
      },
      "PreviousState": {
        "Code": 16,
        "Name": "running"
      }
    },
    {
      "InstanceId": "i-004f291c4441da411",
      "CurrentState": {
        "Code": 32,
        "Name": "shutting-down"
      },
      "PreviousState": {
        "Code": 16,
        "Name": "running"
      }
    }
  ]
}
```

### Delete Auto Scaling Group

```bash
(bash) $ aws autoscaling delete-auto-scaling-group --auto-scaling-group-name asg-autoscaling
```

### Delete Launch Template

```bash
(bash) $ aws ec2 describe-launch-templates
```

```bash
(bash) $ aws ec2 delete-launch-template --launch-template-name asg-template
```

### Remove Security Groups

If you try to remove any of the security groups you'll get an error because each SG is being used by each other. Let's try:

```bash
(bash) $ aws ec2 delete-security-group --group-name asg-elb-sg
----------------
An error occurred (DependencyViolation) when calling the DeleteSecurityGroup operation: resource sg-0711cbbfafffcfc90 has a dependent object
```

#### Revoke reference

Why can remove any of the two references, let's verify the egress rules for the asg-elb-sg group:

```bash
(bash) $ aws ec2 describe-security-groups --group-name asg-elb-sg | jq '.SecurityGroups | .[0] | .IpPermissionsEgress'
```

Output:

```json
[
  {
    "PrefixListIds": [],
    "FromPort": 80,
    "IpRanges": [],
    "ToPort": 80,
    "IpProtocol": "tcp",
    "UserIdGroupPairs": [
      {
        "UserId": "436887685341",
        "GroupId": "sg-0e2ef5fc627df4419"
      }
    ],
    "Ipv6Ranges": []
  }
]
```

Now let's revoke that rule:

```bash
(bash) $ aws ec2 revoke-security-group-egress --group-id sg-0711cbbfafffcfc90 --protocol tcp --port 80 --source-group sg-0e2ef5fc627df4419
```

What we did? We removed the reference from `asg-elb-sg` to `asg-elb-ec2-sg`. `asg-elb-ec2-sg` still has a reference to `asg-elb-sg`, but `asg-elb-ec2-sg` is not being referenced from anywhere, so it's safe to remove it:

```bash
(bash) $ aws ec2 delete-security-group --group-name asg-elb-ec2-sg
```

With that we removed the reference from `asg-elb-ec2-sg` to `asg-elb-sg`, and we can remove it as well:

```bash
(bash) $ aws ec2 delete-security-group --group-name asg-elb-sg
```
