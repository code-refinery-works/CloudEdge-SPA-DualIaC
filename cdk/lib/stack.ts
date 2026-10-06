import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as origins from "aws-cdk-lib/aws-cloudfront-origins";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as route53 from "aws-cdk-lib/aws-route53";
import * as targets from "aws-cdk-lib/aws-route53-targets";
import * as wafv2 from "aws-cdk-lib/aws-wafv2";
import { aws_iam as iam } from "aws-cdk-lib";

interface EdgeProps extends cdk.StackProps {
  project: string; envName: string; domainName: string; hostedZoneName: string;
}
interface HostingProps extends EdgeProps {
  certificate: acm.ICertificate; webAclArn: string;
}

// ── us-east-1 Stack: ACM + WAF ─────────────────────────────────────
export class SpaHostingUsEast1Stack extends cdk.Stack {
  readonly certificate: acm.ICertificate;
  readonly webAclArn: string;

  constructor(scope: Construct, id: string, props: EdgeProps) {
    super(scope, id, props);
    const prefix = `${props.project}-${props.envName}`;

    const zone = route53.HostedZone.fromLookup(this, "Zone", {
      domainName: props.hostedZoneName,
    });

    this.certificate = new acm.Certificate(this, "Cert", {
      domainName: props.domainName,
      subjectAlternativeNames: [`www.${props.domainName}`],
      validation: acm.CertificateValidation.fromDns(zone),
    });

    const waf = new wafv2.CfnWebACL(this, "Waf", {
      name: `${prefix}-waf`,
      scope: "CLOUDFRONT",
      defaultAction: { allow: {} },
      rules: [
        {
          name: "AWSManagedCommon",
          priority: 1,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: { vendorName: "AWS", name: "AWSManagedRulesCommonRuleSet" },
          },
          visibilityConfig: { cloudWatchMetricsEnabled: true, metricName: "common", sampledRequestsEnabled: true },
        },
        {
          name: "RateLimit",
          priority: 2,
          action: { block: {} },
          statement: { rateBasedStatement: { limit: 2000, aggregateKeyType: "IP" } },
          visibilityConfig: { cloudWatchMetricsEnabled: true, metricName: "ratelimit", sampledRequestsEnabled: true },
        },
      ],
      visibilityConfig: { cloudWatchMetricsEnabled: true, metricName: `${prefix}-waf`, sampledRequestsEnabled: true },
    });
    this.webAclArn = waf.attrArn;
  }
}

// ── Primary Stack: S3 + CloudFront ────────────────────────────────
export class SpaHostingStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: HostingProps) {
    super(scope, id, props);
    const prefix = `${props.project}-${props.envName}`;

    // Logs bucket
    const logsBucket = new s3.Bucket(this, "LogsBucket", {
      bucketName: `${prefix}-logs-${this.account}`,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_PREFERRED,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [{ id: "archive", transitions: [{ storageClass: s3.StorageClass.GLACIER, transitionAfter: cdk.Duration.days(90) }] }],
    });

    // Content bucket
    const contentBucket = new s3.Bucket(this, "ContentBucket", {
      bucketName: `${prefix}-content-${this.account}`,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      versioned: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      autoDeleteObjects: false,
    });

    // CloudFront Function: SPA router + security headers
    const spaFunction = new cloudfront.Function(this, "SpaFunction", {
      functionName: `${prefix}-spa-router`,
      runtime: cloudfront.FunctionRuntime.JS_2_0,
      code: cloudfront.FunctionCode.fromInline(`
function handler(event) {
  var req = event.request;
  var uri = req.uri;
  if (uri.endsWith('/')) { req.uri = uri + 'index.html'; }
  else if (!uri.includes('.')) { req.uri = '/index.html'; }
  req.headers['x-content-type-options'] = [{key:'X-Content-Type-Options',value:'nosniff'}];
  req.headers['x-frame-options']        = [{key:'X-Frame-Options',value:'DENY'}];
  req.headers['referrer-policy']        = [{key:'Referrer-Policy',value:'strict-origin-when-cross-origin'}];
  return req;
}`),
    });

    // CloudFront Distribution
    const distribution = new cloudfront.Distribution(this, "Distribution", {
      defaultRootObject: "index.html",
      domainNames: [props.domainName, `www.${props.domainName}`],
      certificate: props.certificate,
      webAclId: props.webAclArn,
      minimumProtocolVersion: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
      enableIpv6: true,
      logBucket: logsBucket,
      logFilePrefix: "cloudfront/",
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(contentBucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        compress: true,
        functionAssociations: [{ function: spaFunction, eventType: cloudfront.FunctionEventType.VIEWER_REQUEST }],
      },
      errorResponses: [
        { httpStatus: 403, responseHttpStatus: 200, responsePagePath: "/index.html", ttl: cdk.Duration.seconds(0) },
        { httpStatus: 404, responseHttpStatus: 200, responsePagePath: "/index.html", ttl: cdk.Duration.seconds(0) },
      ],
    });

    // Route 53
    const zone = route53.HostedZone.fromLookup(this, "Zone", { domainName: props.hostedZoneName });
    const cfTarget = new targets.CloudFrontTarget(distribution);
    new route53.ARecord(this, "AliasApex", { zone, recordName: props.domainName, target: route53.RecordTarget.fromAlias(cfTarget) });
    new route53.ARecord(this, "AliasWww",  { zone, recordName: `www.${props.domainName}`, target: route53.RecordTarget.fromAlias(cfTarget) });

    // Outputs
    new cdk.CfnOutput(this, "DistributionId",   { value: distribution.distributionId });
    new cdk.CfnOutput(this, "DistributionDomain", { value: distribution.distributionDomainName });
    new cdk.CfnOutput(this, "ContentBucket",    { value: contentBucket.bucketName });
    new cdk.CfnOutput(this, "SiteUrl",          { value: `https://${props.domainName}` });
  }
}