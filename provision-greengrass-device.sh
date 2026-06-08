#!/bin/bash
set -e

THING_NAME="MyGreengrassCore"
THING_GROUP="MyGreengrassCoreGroup"
REGION="us-west-2"
IOT_POLICY_NAME="GreengrassV2IoTThingPolicy"
ROLE_NAME="GreengrassV2TokenExchangeRole"
ROLE_ALIAS="GreengrassCoreTokenExchangeRoleAlias"
ACCESS_POLICY_NAME="GreengrassV2TokenExchangeRoleAccess"
ROLE_ALIAS_POLICY_NAME="GreengrassCoreTokenExchangeRoleAliasPolicy"
CERT_DIR="greengrass-v2-certs"

# =========================================
# STEP 1: Obtain AWS IoT Endpoints
#   Required for your device config; endpoints enable the device to connect to AWS IoT services.
# =========================================
echo "Getting AWS IoT endpoints..."
IOT_DATA_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query 'endpointAddress' --output text --region $REGION)
IOT_CRED_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:CredentialProvider --query 'endpointAddress' --output text --region $REGION)

# =========================================
# STEP 2: Register your Greengrass Core as an IoT Thing
#   IoT Things represent devices in AWS and enable certificate-based authentication.
# =========================================
echo "Creating IoT Thing..."
aws iot create-thing --thing-name $THING_NAME --region $REGION

# =========================================
# STEP 3: (Optional) Group IoT Thing with Thing Group
#   Thing Groups allow you to organize and deploy components to many devices in bulk.
# =========================================
echo "Creating Thing Group (optional)..."
aws iot create-thing-group --thing-group-name $THING_GROUP --region $REGION || true
aws iot add-thing-to-thing-group --thing-name $THING_NAME --thing-group-name $THING_GROUP --region $REGION || true

# =========================================
# STEP 4: Create and Download Device Certificates
#   Certificates allow secure and authenticated device communication with AWS IoT.
# =========================================
echo "Creating certificates..."
mkdir -p $CERT_DIR
CERT_RESPONSE=$(aws iot create-keys-and-certificate --set-as-active \
  --certificate-pem-outfile $CERT_DIR/device.pem.crt \
  --public-key-outfile $CERT_DIR/public.pem.key \
  --private-key-outfile $CERT_DIR/private.pem.key \
  --region $REGION)

CERT_ARN=$(echo $CERT_RESPONSE | grep -o '"certificateArn":.*' | awk -F'"' '{print $4}')
echo "Certificate ARN: $CERT_ARN"

# ===============================================================
# STEP 5: Create and Attach IoT Policy to Certificate
#   This policy grants your device permission to connect, publish/subscribe, and interact with Greengrass.
#      Without this, your device can authenticate but cannot access AWS IoT functions or Greengrass components.
# ===============================================================
echo "Creating device IoT policy and attaching to the certificate..."

cat > greengrass-v2-iot-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iot:Publish",
        "iot:Subscribe",
        "iot:Receive",
        "iot:Connect",
        "greengrass:*"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF

aws iot create-policy --policy-name $IOT_POLICY_NAME --policy-document file://greengrass-v2-iot-policy.json --region $REGION || true
aws iot attach-policy --policy-name $IOT_POLICY_NAME --target $CERT_ARN --region $REGION

aws iot attach-thing-principal --thing-name $THING_NAME --principal $CERT_ARN --region $REGION

# ==========================================================================================
# STEP 6: Create Token Exchange IAM Role and Role Alias (Allow S3/log access from device)
#   Greengrass Core uses this IAM role to securely access AWS services (S3 for models, CloudWatch for logs).
#      The role alias lets devices assume temporary AWS credentials using their certificate.
# ==========================================================================================
echo "Creating token exchange IAM role, policies, and role alias..."

cat > device-role-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "credentials.iot.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://device-role-trust-policy.json --region $REGION || true

cat > device-role-access-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy --policy-name $ACCESS_POLICY_NAME --policy-document file://device-role-access-policy.json --region $REGION || true
ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text --region $REGION)
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$ACCESS_POLICY_NAME'].Arn" --output text --region $REGION)
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN --region $REGION

aws iot create-role-alias --role-alias $ROLE_ALIAS --role-arn $ROLE_ARN --region $REGION || true
ROLE_ALIAS_ARN="arn:aws:iot:$REGION:$(aws sts get-caller-identity --query Account --output text):rolealias/$ROLE_ALIAS"

cat > greengrass-v2-iot-role-alias-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iot:AssumeRoleWithCertificate",
      "Resource": "$ROLE_ALIAS_ARN"
    }
  ]
}
EOF

aws iot create-policy --policy-name $ROLE_ALIAS_POLICY_NAME --policy-document file://greengrass-v2-iot-role-alias-policy.json --region $REGION || true
aws iot attach-policy --policy-name $ROLE_ALIAS_POLICY_NAME --target $CERT_ARN --region $REGION

# ==========================================================
# STEP 7: Download Amazon Root CA Certificate
#   Required by all IoT devices to establish a trust chain with AWS IoT Core
# ==========================================================
echo "Downloading Amazon Root CA..."
wget -O $CERT_DIR/AmazonRootCA1.pem https://www.amazontrust.com/repository/AmazonRootCA1.pem

# ==========================================================
# STEP 8: Generate Greengrass Config File for Installer
#   Supplies the device with all endpoints, roles, and certificate paths needed for Greengrass install.
# ==========================================================
echo "Generating Greengrass config file..."

cat > config.yaml <<EOF
---
system:
  certificateFilePath: "$CERT_DIR/device.pem.crt"
  privateKeyPath: "$CERT_DIR/private.pem.key"
  rootCaPath: "$CERT_DIR/AmazonRootCA1.pem"
  rootpath: "<YOUR_GREENGRASS_ROOT_PATH>"         # Update for your device (e.g. /greengrass/v2 or C:/greengrass/v2)
  thingName: "$THING_NAME"
services:
  aws.greengrass.Nucleus:
    componentType: "NUCLEUS"
    version: "2.15.0"
    configuration:
      awsRegion: "$REGION"
      iotRoleAlias: "$ROLE_ALIAS"
      iotDataEndpoint: "$IOT_DATA_ENDPOINT"
      iotCredEndpoint: "$IOT_CRED_ENDPOINT"
EOF

echo ""
echo "=== Completed AWS IoT Greengrass device provisioning! ==="
echo "Next: Copy $CERT_DIR/ and config.yaml to your device's Greengrass install directory."
echo "Check the installation steps according to your OS here: https://docs.aws.amazon.com/greengrass/v2/developerguide/manual-installation.html#set-up-device-environment"
