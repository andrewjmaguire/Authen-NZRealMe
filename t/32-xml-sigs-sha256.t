#!perl

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Spec;
use lib File::Spec->catdir($FindBin::Bin, 'test-lib');

use AuthenNZRealMeTestHelper;
use AuthenNZRealMeSigTestHelper;
use Authen::NZRealMe;
use XML::LibXML;
use Digest::SHA     qw(sha256);
use MIME::Base64    qw(encode_base64);

my $algorithm      = 'sha256';
my $dsig_ns        = 'http://www.w3.org/2000/09/xmldsig#';
my $uri_exc_c14n   = 'http://www.w3.org/2001/10/xml-exc-c14n#';
my $uri_rsa_sha256 = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256';
my $uri_env_sig    = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature';
my $uri_sha256     = 'http://www.w3.org/2001/04/xmlenc#sha256';

my $dispatcher  = 'Authen::NZRealMe';
my $sig_class   = $dispatcher->class_for('xml_signer');

ok($INC{'Authen/NZRealMe/XMLSig.pm'}, "loaded Authen::NZRealMe::XMLSig module");

my %init = (
    algorithm => 'algorithm_sha256',
);

my $signer = $sig_class->new(%init);
isa_ok($signer,             'Authen::NZRealMe::XMLSig');
isa_ok($signer->_algorithm, 'Authen::NZRealMe::XMLSig::Algorithm::sha256', 'using sha256 algorithm');
is($signer->id_attr, 'ID',  'default ID attribute name');

my $xml = '<assertion id="onetwothree"><attribute name="surname">Bloggs</attribute></assertion>';

my $target_id = 'onetwothree';
my $key_file  = test_conf_file('sp-sign-key.pem');
ok(-e $key_file, "test key file exists: $key_file");

$signer = $sig_class->new(
    %init,
    id_attr   => 'id',
    key_file  => $key_file,
);
is($signer->id_attr, 'id', 'overrode ID attribute name');

my $signed = eval{
    $signer->sign($xml, $target_id);
};

is("$@", '', 'signed doc');
like($signed, qr{\A<.*>\z}s, 'return value look like XML');

my $parser = XML::LibXML->new();
my $dom = $parser->parse_string($signed);
my $doc = $dom->getDocumentElement();
my $xc  = XML::LibXML::XPathContext->new($dom);
$xc->registerNs( DSIG => $dsig_ns );

is($doc->nodeName, 'assertion', 'parsed signed assertion');

my @children = $xc->findnodes('/*/*');
is(scalar(@children), 2, 'signed doc has new element under root');

my($sig) = @children;
is($sig->localName, 'Signature', 'is a <Signature> element');
is($sig->namespaceURI, $dsig_ns, 'in xmldsig namespace');

my($c14n_method) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:CanonicalizationMethod/@Algorithm}
);
is($c14n_method, $uri_exc_c14n, 'c14n method from SignedInfo');

my($sig_method) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:SignatureMethod/@Algorithm}
);
is($sig_method, $uri_rsa_sha256, 'signature method from SignedInfo');

my $sig_algorithm = Authen::NZRealMe->new_algorithm_from_SignatureMethod($sig_method);
isa_ok($sig_algorithm, 'Authen::NZRealMe::XMLSig::Algorithm::sha256', 'algorithm class from SignatureMethod');
is($sig_method, $sig_algorithm->SignatureMethod(), 'signature method matches algorithm->SignatureMethod()');

my($ref_uri) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:Reference/@URI}
);
is($ref_uri, '#' . $target_id, 'reference to signed element');

my @transforms = map { $_->to_literal } $xc->findnodes(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:Reference/DSIG:Transforms/DSIG:Transform/@Algorithm}
);
is(scalar(@transforms), 2, '2 signature transforms');
is($transforms[0], $uri_env_sig, '1st transform');
is($transforms[1], $uri_exc_c14n, '2nd transform');

my($digest_method) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:Reference/DSIG:DigestMethod/@Algorithm}
);
is($digest_method, $uri_sha256, 'digest method');

my $digest_algorithm = Authen::NZRealMe->new_algorithm_from_DigestMethod($digest_method);
isa_ok($digest_algorithm, 'Authen::NZRealMe::XMLSig::Algorithm::sha256', 'algorithm class from DigestMethod');
is($digest_method, $digest_algorithm->DigestMethod(), 'digest method matches algorithm->DigestMethod()');

my($digest_from_xml) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:Reference/DSIG:DigestValue}
);

# Separate signature from signed doc
my($signature) = $signed =~ m{(<\w+:Signature\b.*</\w+:Signature>)}s;
$signed =~ s{<\w+:Signature\b.*</\w+:Signature>}{}s;
is($signed, $xml, 'source XML is otherwise unchanged');

my $bin_digest = sha256($xml);
my $sha1_digest = encode_base64($bin_digest, '');
is($sha1_digest, $digest_from_xml, 'manual digest matches digest from sig');

my($sig_value_from_xml) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignatureValue}
);
$sig_value_from_xml =~ s/\s+//g;

my($sig_info) = $xc->findnodes(q{//DSIG:Signature/DSIG:SignedInfo});
my $plaintext = $sig_info->toStringEC14N(0, '', [$dsig_ns]);
my($key_text) = $signer->_slurp_file($key_file);
my $rsa_key = Crypt::OpenSSL::RSA->new_private_key($key_text);
$rsa_key->use_pkcs1_oaep_padding();
$rsa_key->use_sha256_hash();
my $bin_signature = $rsa_key->sign($plaintext);
my $sig_value = encode_base64($bin_signature, '');

is($sig_value, $sig_value_from_xml, 'base64 encoded signature');

##############################################################################
# Verify a signature

my $signed_xml = AuthenNZRealMeSigTestHelper::sign(
    key_file  => 'idp-assertion-sign-key.pem',
    xml_file  => 'xml-sigs-source.xml',
    sig_alg   => 'algorithm_sha256',
    command   => 'sign_one_ref',
    targets   => [ 'fourfivesix' ],
);

my $container_xml = <<EOF;
<container>
  <comment>This bit is outside the signed area and was added after signing</comment>
  $signed_xml
  <comment>Also outside the signed area and added after signing</comment>
</container>
EOF

my $idp_cert_file = test_conf_file('idp-assertion-sign-crt.pem');
my $verifier = eval {
    $sig_class->new(
        pub_cert_text  => $signer->_slurp_file($idp_cert_file),
    );
};
is("$@", '', 'created object for verifying sigs');

my $result = eval {
    $verifier->verify($container_xml,
                      inline_certificate_check => 'never');
};
is("$@", '', 'verified sigs without throwing exception');
ok($result, 'verify method returned true');


##############################################################################
# Now try a doc with a bad signature

my $tampered_xml = $container_xml;
$tampered_xml =~ s/Pinetree/Mr 'Pinetree'/;

$result = eval {
    $verifier->verify($tampered_xml,
                      inline_certificate_check => 'never');
};
is($result, undef, 'verification of signed-but-tampered document failed');
like(
    "$@",
    qr{Digest of signed element 'fourfivesix' differs from that given in reference block},
    'with appropriate message'
);

done_testing();

exit;
