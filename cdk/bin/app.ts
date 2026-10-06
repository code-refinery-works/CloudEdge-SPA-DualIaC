#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { SpaHostingUsEast1Stack } from "../lib/stack";
import { SpaHostingStack } from "../lib/stack";

const app = new cdk.App();

const project = app.node.tryGetContext("project") ?? "myapp";
const env_name = app.node.tryGetContext("env") ?? "prod";
const domainName: string = app.node.tryGetContext("domainName");
const hostedZoneName: string = app.node.tryGetContext("hostedZoneName");

if (!domainName || !hostedZoneName) {
  throw new Error(
    "Required context: -c domainName=example.com -c hostedZoneName=example.com"
  );
}

// us-east-1 stack: ACM cert + WAF WebACL
const usEast1Stack = new SpaHostingUsEast1Stack(app, `${project}-${env_name}-edge`, {
  env: { region: "us-east-1" },
  crossRegionReferences: true,
  project,
  envName: env_name,
  domainName,
  hostedZoneName,
});

// Primary stack: S3 + CloudFront (may be any region)
new SpaHostingStack(app, `${project}-${env_name}-hosting`, {
  env: { region: process.env.CDK_DEFAULT_REGION ?? "ap-northeast-1" },
  crossRegionReferences: true,
  project,
  envName: env_name,
  domainName,
  hostedZoneName,
  certificate: usEast1Stack.certificate,
  webAclArn: usEast1Stack.webAclArn,
});